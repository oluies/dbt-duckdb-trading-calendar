package fxregimes

import com.raquo.laminar.api.L.*
import org.scalajs.dom
import scala.scalajs.concurrent.JSExecutionContext.Implicits.queue
import scala.scalajs.js
import scala.scalajs.js.JSConverters.*
import scala.scalajs.js.annotation.JSGlobal
import scala.util.{Failure, Success}

/** duckdb-bridge.js: DuckDB-WASM with the cpt extension loaded. */
@js.native
@JSGlobal("FxDuck")
object FxDuck extends js.Object:
  def start(returns: js.Array[Double], extensionUrl: String): js.Promise[DuckSession] = js.native

@js.native
trait DuckSession extends js.Object:
  def run(penalty: String, minDays: Int): js.Promise[js.Array[Segment]] = js.native

/** One row of cpt_segment_stats; start and end are 1-based positions in the returns. */
@js.native
trait Segment extends js.Object:
  val start: Int = js.native
  val end: Int = js.native
  val n: Int = js.native
  val mean: Double = js.native
  val variance: Double = js.native

enum Penalty(val key: String, val label: String):
  case Mbic extends Penalty("mbic", "MBIC")
  case Bic extends Penalty("bic", "BIC")
  case Aic extends Penalty("aic", "AIC")
  case Custom extends Penalty("custom", "Custom")

final case class Params(penalty: Penalty, customBeta: Int, minDays: Int):
  /** The penalty argument of cpt_pelt. */
  def sql: String = if penalty == Penalty.Custom then customBeta.toString else s"'${penalty.key}'"

/** "Try other parameters": reruns the detection in the reader's browser. */
object Live:

  private val Published = Params(Penalty.Mbic, 32, 20)
  private val PagesUrl = "https://oluies.github.io/dbt-duckdb-trading-calendar/"

  private enum State:
    case Idle, Loading
    case Failed(message: String)
    case Ready(session: DuckSession)

  // The Claude artifact's content policy blocks the wasm engine.
  private val canRunHere = !dom.window.location.hostname.contains("claude")

  def panel(published: FxData, onResult: FxData => Unit): HtmlElement =
    val state = Var[State](State.Idle)
    val params = Var(Published)

    def load(): Unit =
      state.set(State.Loading)
      val returns = published.returnDays.flatMap(_.ret).toJSArray
      FxDuck.start(returns, "cpt.duckdb_extension.wasm").toFuture.onComplete {
        case Success(session) => state.set(State.Ready(session))
        case Failure(e)       => state.set(State.Failed(e.getMessage))
      }

    sectionTag(
      cls := "live",
      h2("Try other parameters"),
      if !canRunHere then
        p(
          "Rerunning the detection needs the ",
          a(href := PagesUrl, "GitHub Pages version"),
          " of this page; this host does not allow the DuckDB engine to load."
        )
      else
        div(
          child <-- state.signal.map {
            case State.Idle =>
              div(
                cls := "live-intro",
                p("Rerun the change point detection in your browser, with DuckDB-WASM and the cpt extension. It downloads about 7 MB."),
                button(typ := "button", "Load DuckDB", onClick --> (_ => load()))
              )
            case State.Loading => p(role := "status", "Loading DuckDB and the cpt extension…")
            case State.Failed(message) =>
              div(
                cls := "live-intro",
                p(role := "alert", s"Could not start DuckDB in this browser: $message"),
                button(typ := "button", "Try again", onClick --> (_ => load()))
              )
            case State.Ready(session) => controls(published, session, params, onResult)
          }
        )
    )

  private def controls(published: FxData, session: DuckSession, params: Var[Params], onResult: FxData => Unit): HtmlElement =
    val status = Var(s"${published.regimes.size} regimes with the published settings.")
    val lnN = math.log(published.returnDays.size.toDouble)

    def beta(p: Params): String = p.penalty match
      case Penalty.Mbic   => f"β ≈ ${4 * lnN}%.1f"
      case Penalty.Bic    => f"β ≈ ${3 * lnN}%.1f"
      case Penalty.Aic    => "β = 6"
      case Penalty.Custom => s"β = ${p.customBeta}"

    def regimesOf(segments: js.Array[Segment]): FxData =
      val days = published.returnDays
      published.copy(regimes = segments.toVector.zipWithIndex.map { (s, i) =>
        Regime(i + 1, days(s.start - 1).date, days(s.end - 1).date, s.n, s.mean, math.sqrt(s.variance), math.sqrt(s.variance * 252))
      })

    div(
      cls := "controls",
      label(
        "Penalty ",
        select(
          idAttr := "penalty",
          Penalty.values.toList.map(p => option(value := p.key, p.label)),
          controlled(
            value <-- params.signal.map(_.penalty.key),
            onChange.mapToValue --> (k => params.update(_.copy(penalty = Penalty.values.find(_.key == k).get)))
          )
        ),
        span(cls := "value", text <-- params.signal.map(beta))
      ),
      child.maybe <-- params.signal.map(_.penalty == Penalty.Custom).distinct.map {
        case false => None
        case true =>
          Some(
            label(
              "β ",
              input(
                typ := "range",
                minAttr := "1",
                maxAttr := "150",
                controlled(
                  value <-- params.signal.map(_.customBeta.toString),
                  onInput.mapToValue --> (v => params.update(_.copy(customBeta = v.toInt)))
                )
              )
            )
          )
      },
      label(
        "Shortest regime ",
        input(
          typ := "range",
          minAttr := "5",
          maxAttr := "120",
          controlled(
            value <-- params.signal.map(_.minDays.toString),
            onInput.mapToValue --> (v => params.update(_.copy(minDays = v.toInt)))
          )
        ),
        span(cls := "value", text <-- params.signal.map(p => s"${p.minDays} days"))
      ),
      button(
        typ := "button",
        "Published settings",
        onClick.mapTo(Published) --> params
      ),
      p(cls := "result", role := "status", text <-- status.signal),
      // flatMapSwitch: a slower, older run never overwrites a newer one.
      params.signal.changes.debounce(50).flatMapSwitch { p =>
        val started = js.Date.now()
        EventStream.fromJsPromise(session.run(p.sql, p.minDays), emitOnce = true).recoverToTry.map(_.map((_, js.Date.now() - started)))
      } --> {
        case Success((segments, ms)) =>
          onResult(regimesOf(segments))
          val noLabels = if segments.length > 40 then "; too many to label on the chart" else ""
          status.set(f"${segments.length} regime${if segments.length == 1 then "" else "s"} in $ms%.0f ms$noLabels.")
        case Failure(e) => status.set(s"The detection failed: ${e.getMessage}")
      }
    )
