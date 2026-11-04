package fxregimes

import com.raquo.laminar.api.L.*
import org.scalajs.dom
import scala.util.{Failure, Success, Try}

object Main:
  def main(args: Array[String]): Unit =
    renderOnDomContentLoaded(dom.document.getElementById("app"), App.view)

object App:

  def view: HtmlElement =
    val loaded: Signal[Option[Try[FxData]]] =
      FetchStream.get("fx_regimes.json").map(FxData.parse).recoverToTry.toWeakSignal
    mainTag(
      h1("SEK/EUR volatility regimes"),
      p(
        cls := "sub",
        "PELT change points (cpt DuckDB extension, normal cost) in the daily log return of the Riksbank ",
        "SEK/EUR fixing, over Nasdaq Stockholm trading days. Click a regime to zoom; double-click the chart to reset."
      ),
      child <-- loaded.map {
        case None              => p(cls := "status", "Loading the SEK/EUR series…")
        case Some(Failure(e))  => p(cls := "status", s"Could not load fx_regimes.json: ${e.getMessage}")
        case Some(Success(fx)) => ready(fx)
      },
      footerTag(
        "Data: Sveriges Riksbank, series SEKEURPMI. Regimes: ",
        a(href := "https://github.com/hugr-lab/duck-changepoint", "cpt"),
        ". Built with ",
        a(href := "https://laminar.dev", "Laminar"),
        " and ",
        a(href := "https://www.tradingview.com/lightweight-charts/", "TradingView Lightweight Charts"),
        "."
      )
    )

  private def ready(fx: FxData): HtmlElement =
    val hovered = Var(Option.empty[String])
    val selected = Var(Option.empty[Int])
    val last = fx.days.last

    div(
      div(cls := "legend", child <-- hovered.signal.map(t => legend(fx, t.flatMap(d => fx.days.find(_.date == d)).getOrElse(last)))),
      div(
        cls := "chart",
        onMountUnmountCallbackWithState(
          mount = ctx =>
            val chart = RegimeChart(ctx.thisNode.ref, fx, hovered.set)
            selected.signal.foreach(n => chart.zoom(n.flatMap(i => fx.regimes.find(_.n == i))))(ctx.owner)
            chart
          ,
          unmount = (_, chart) => chart.foreach(_.dispose())
        ),
        onDblClick.mapTo(None) --> selected
      ),
      div(cls := "wrap", regimeTable(fx, selected))
    )

  private def legend(fx: FxData, d: Day): HtmlElement =
    val ret = d.ret.fold("–")(r => f"${if r >= 0 then "+" else ""}$r%.2f%%")
    span(
      b(d.date),
      f"  ${d.rate}%.4f SEK/EUR   return $ret",
      fx.regimeOf(d.date).map { r =>
        span(
          swatch(fx.color(r)),
          f"regime R${r.n}: ${r.annualVolPct}%.1f%% annualised vol, ${r.start} → ${r.end}"
        )
      }
    )

  private def swatch(color: String): HtmlElement = span(cls := "swatch", backgroundColor := color)

  private def regimeTable(fx: FxData, selected: Var[Option[Int]]): HtmlElement =
    table(
      cls := "regimes",
      thead(tr(th("#"), th("Regime"), th("Trading days"), th("Mean return %"), th("Daily vol %"), th("Annualised vol %"))),
      tbody(
        fx.regimes.map { r =>
          tr(
            cls("active") <-- selected.signal.map(_.contains(r.n)),
            onClick.mapTo(Some(r.n)) --> selected,
            td(swatch(fx.color(r)), s"R${r.n}"),
            td(s"${r.start} → ${r.end}"),
            td(r.tradingDays.toString),
            td(f"${r.meanPct}%.3f"),
            td(f"${r.dailyVolPct}%.3f"),
            td(f"${r.annualVolPct}%.1f")
          )
        }
      )
    )
