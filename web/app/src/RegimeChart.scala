package fxregimes

import org.scalajs.dom
import scala.scalajs.js
import scala.scalajs.js.JSConverters.*
import scala.scalajs.js.Dynamic.literal as obj

/** The Lightweight Charts part of the page: rate over regime bands (pane 0),
  * returns with each regime's mean +- 2 sigma band (pane 1).
  *
  * `applyPalette` recolours everything when the theme changes; `show` draws a
  * different set of regimes over the same days and keeps the zoom.
  */
final class RegimeChart(container: dom.HTMLElement, initial: FxData, onHover: Option[String] => Unit):
  private val LC = LightweightCharts
  private var data = initial
  private var palette = Option.empty[Palette]

  /** Above this many regimes the labels would cover the chart. */
  private val MaxMarkers = 40

  private val chart = LC.createChart(
    container,
    obj(
      autoSize = true,
      layout = obj(fontSize = 12),
      // ~3000 daily points: allow sub-pixel bars so fitContent shows them all.
      timeScale = obj(minBarSpacing = 0.05, fixLeftEdge = true, fixRightEdge = true),
      crosshair = obj(mode = LC.CrosshairMode.Normal)
    )
  )

  // One full-height area on a hidden 0..1 overlay scale, coloured point by
  // point: a histogram would leave gaps between sub-pixel bars, and a series
  // per regime would not scale to the hundreds a low penalty produces.
  private val bands = chart.addSeries(
    LC.AreaSeries,
    obj(
      priceScaleId = "bands",
      lineVisible = false,
      lastValueVisible = false,
      priceLineVisible = false,
      crosshairMarkerVisible = false,
      autoscaleInfoProvider = (() => obj(priceRange = obj(minValue = 0, maxValue = 1))): js.Function0[js.Object]
    )
  )
  chart.priceScale("bands").applyOptions(obj(scaleMargins = obj(top = 0, bottom = 0), visible = false))

  private val rate = chart.addSeries(
    LC.LineSeries,
    obj(lineWidth = 1, title = "SEK/EUR", priceFormat = obj(`type` = "price", precision = 4, minMove = 0.0001))
  )
  rate.setData(initial.days.map(d => obj(time = d.date, value = d.rate): js.Object).toJSArray)

  private val returns = chart.addSeries(
    LC.HistogramSeries,
    obj(
      title = "log return %",
      lastValueVisible = false,
      priceLineVisible = false,
      priceFormat = obj(`type` = "price", precision = 2, minMove = 0.01)
    ),
    1
  )
  returns.setData(initial.returnDays.map(d => obj(time = d.date, value = d.ret.get): js.Object).toJSArray)

  private def sigmaBand(): ISeriesApi =
    chart.addSeries(
      LC.LineSeries,
      obj(
        lineWidth = 1,
        lineType = LC.LineType.WithSteps,
        lastValueVisible = false,
        priceLineVisible = false,
        crosshairMarkerVisible = false
      ),
      1
    )
  private val upper = sigmaBand()
  private val lower = sigmaBand()

  private val markers = LC.createSeriesMarkers(rate, js.Array())

  // Relative pane sizes: a fixed height can push the time axis out of view.
  chart.panes()(0).setStretchFactor(2.2)
  chart.panes()(1).setStretchFactor(1)
  chart.timeScale().fitContent()

  chart.subscribeCrosshairMove(p => onHover(p.time.toOption))

  private def alpha(hex: String, a: Double): String = f"$hex${math.round(a * 255).toInt}%02x"

  def applyPalette(p: Palette): Unit =
    palette = Some(p)
    chart.applyOptions(
      obj(
        layout = obj(background = obj(color = p.bg), textColor = p.muted, panes = obj(separatorColor = p.line)),
        grid = obj(vertLines = obj(color = p.line), horzLines = obj(color = p.line)),
        rightPriceScale = obj(borderColor = p.line),
        timeScale = obj(borderColor = p.line)
      )
    )
    rate.applyOptions(obj(color = p.fg))
    returns.applyOptions(obj(color = alpha(p.muted, 0.8)))
    render()

  /** Draw these regimes; the days are the same, so the zoom stays where it is. */
  def show(fx: FxData): Unit =
    data = fx
    render()

  private def render(): Unit = palette.foreach { p =>
    val colour = data.regimes.map(r => r.n -> data.color(r, p.ramp)).toMap
    // Stronger fills for more volatile regimes, so the stress periods stand out.
    val fill = data.regimes.map(r => r.n -> alpha(colour(r.n), p.bandAlpha * (0.7 + 0.9 * data.intensity(r)))).toMap
    // A point's colour fills the stretch up to the next point, and a return
    // covers the interval since the previous fixing, so each point takes the
    // regime of the next day's return: a band starts one fixing before its
    // first return, and neighbouring bands meet.
    val closing = data.regimeOfDay.drop(1) :+ data.regimeOfDay.last
    bands.setData(data.days.lazyZip(closing).map { (d, r) =>
      obj(time = d.date, value = 1, topColor = fill(r.n), bottomColor = fill(r.n)): js.Object
    }.toJSArray)
    val withReturn = data.days.lazyZip(data.regimeOfDay).collect { case (d, r) if d.ret.isDefined => (d, r) }
    def sigma(sign: Int) = withReturn.map { (d, r) =>
      obj(time = d.date, value = r.meanPct + sign * 2 * r.dailyVolPct, color = colour(r.n)): js.Object
    }.toJSArray
    upper.setData(sigma(+1))
    lower.setData(sigma(-1))
    // Labels in the text colour: a regime's own colour on its band is too
    // faint for 4.5:1. Stress regimes get an arrow and their volatility,
    // above the line; the rest a dot below, so neighbouring labels part.
    markers.setMarkers(
      if data.regimes.size > MaxMarkers then js.Array()
      else
        data.regimes.map { r =>
          val stress = data.isStress(r)
          obj(
            time = r.start,
            position = if stress then "aboveBar" else "belowBar",
            shape = if stress then "arrowDown" else "circle",
            size = if stress then 1.2 else 0.6,
            color = p.fg,
            text = if stress then f"R${r.n} ${r.annualVolPct}%.1f%% vol" else s"R${r.n}"
          ): js.Object
        }.toJSArray
    )
  }

  /** Zoom to a regime with a margin of 15% of its length (at least 10 days), or show everything. */
  def zoom(regime: Option[Regime]): Unit = regime match
    case None => chart.timeScale().fitContent()
    case Some(r) =>
      val margin = math.max(10, math.round(r.tradingDays * 0.15).toInt)
      chart.timeScale().setVisibleRange(obj(from = shiftDays(r.start, -margin), to = shiftDays(r.end, margin)))

  private def shiftDays(iso: String, days: Int): String =
    val t = new js.Date(iso)
    t.setUTCDate(t.getUTCDate() + days)
    t.toISOString().take(10)

  def dispose(): Unit = chart.remove()
