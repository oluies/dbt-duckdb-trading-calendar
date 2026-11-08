package fxregimes

import com.raquo.laminar.api.L.*
import org.scalajs.dom
import scala.util.{Failure, Success, Try}

object Main:
  def main(args: Array[String]): Unit =
    Theme.install()
    renderOnDomContentLoaded(dom.document.getElementById("app"), App.view)

object App:

  def view: HtmlElement =
    val loaded: Signal[Option[Try[FxData]]] =
      FetchStream.get("fx_regimes.json").map(FxData.parse).recoverToTry.toWeakSignal
    mainTag(
      headerTag(
        cls := "top",
        div(
          h1("SEK/EUR volatility regimes"),
          p(
            cls := "sub",
            "PELT change points (cpt DuckDB extension, normal cost) in the daily log return of the Riksbank ",
            "SEK/EUR fixing, over Nasdaq Stockholm trading days. Choose a regime in the table to zoom to it."
          )
        ),
        Theme.picker
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
    // The regimes on screen: the published ones until the reader reruns the detection.
    val active = Var(fx)

    div(
      div(
        cls := "toolbar",
        div(
          cls := "legend",
          child <-- hovered.signal.combineWith(active.signal).map((t, shown) =>
            legend(shown, t.flatMap(d => fx.days.find(_.date == d)).getOrElse(last))
          )
        ),
        button(
          cls := "reset",
          typ := "button",
          // Not disabled when nothing is zoomed: that would drop keyboard focus to the top of the page.
          "Show all",
          onClick.mapTo(None) --> selected
        )
      ),
      div(
        cls := "chart",
        // The canvas has no text of its own; the regime table below carries the same data.
        role := "img",
        aria.label := "Chart of the SEK/EUR rate and its daily returns, 2015 to 2026, shaded by volatility regime. " +
          "The table below lists each regime with its dates and volatility.",
        onMountUnmountCallbackWithState(
          mount = ctx =>
            val chart = RegimeChart(ctx.thisNode.ref, fx, hovered.set)
            selected.signal.foreach(n => chart.zoom(n.flatMap(i => active.now().regimes.find(_.n == i))))(ctx.owner)
            active.signal.changes.foreach(chart.show)(ctx.owner)
            Theme.palette.foreach(chart.applyPalette)(ctx.owner)
            chart
          ,
          unmount = (_, chart) => chart.foreach(_.dispose())
        ),
        onDblClick.mapTo(None) --> selected
      ),
      Live.panel(
        fx,
        rerun =>
          active.set(rerun)
          // The numbering has changed, so the selection no longer means anything.
          if selected.now().nonEmpty then selected.set(None)
      ),
      div(
        cls := "wrap",
        cls("many") <-- active.signal.map(_.regimes.size > 20),
        child <-- active.signal.map(regimeTable(_, selected))
      ),
      Explainer.view(fx)
    )

  private def legend(fx: FxData, d: Day): HtmlElement =
    val ret = d.ret.fold("–")(r => f"${if r >= 0 then "+" else ""}$r%.2f%%")
    span(
      b(d.date),
      f"  ${d.rate}%.4f SEK/EUR   return $ret",
      fx.regimeOf(d.date).map { r =>
        span(
          swatch(fx, r),
          f"regime R${r.n}: ${r.annualVolPct}%.1f%% annualised vol, ${r.start} → ${r.end}"
        )
      }
    )

  /** A regime's colour, following the palette. Decorative: the regime is always named in text beside it. */
  private def swatch(fx: FxData, r: Regime): HtmlElement =
    span(cls := "swatch", aria.hidden := true, backgroundColor <-- Theme.palette.map(p => fx.color(r, p.ramp)))

  private def regimeTable(fx: FxData, selected: Var[Option[Int]]): HtmlElement =
    table(
      cls := "regimes",
      caption(cls := "visually-hidden", "Volatility regimes. Choose a regime to zoom the chart to it."),
      thead(tr(th("#"), th("Regime"), th("Trading days"), th("Mean return %"), th("Daily vol %"), th("Annualised vol %"))),
      tbody(
        fx.regimes.map { r =>
          val isSelected = selected.signal.map(_.contains(r.n))
          tr(
            cls("active") <-- isSelected,
            // The whole row is a mouse target; the button is the keyboard and screen-reader control.
            onClick.mapTo(Some(r.n)) --> selected,
            td(
              button(
                cls := "regime",
                typ := "button",
                aria.pressed <-- isSelected.map(_.toString),
                aria.label := s"Zoom to regime R${r.n}, ${r.start} to ${r.end}",
                swatch(fx, r),
                s"R${r.n}"
              )
            ),
            td(s"${r.start} → ${r.end}"),
            td(r.tradingDays.toString),
            td(f"${r.meanPct}%.3f"),
            td(f"${r.dailyVolPct}%.3f"),
            td(f"${r.annualVolPct}%.1f")
          )
        }
      )
    )
