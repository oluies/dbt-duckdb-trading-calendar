package fxregimes

import scala.scalajs.js
import scala.scalajs.js.annotation.JSGlobal

/** Minimal facade for TradingView Lightweight Charts 5.x, covering only the
  * calls this app makes. The standalone build that index.html loads defines
  * the `LightweightCharts` global. Options are passed as `js.Dynamic.literal`,
  * as in the library's own JavaScript examples.
  */
@js.native
@JSGlobal("LightweightCharts")
object LightweightCharts extends js.Object:
  def createChart(container: org.scalajs.dom.HTMLElement, options: js.Object): IChartApi = js.native
  def createSeriesMarkers(series: ISeriesApi, markers: js.Array[js.Object]): ISeriesMarkers = js.native

  val LineSeries: SeriesDefinition = js.native
  val AreaSeries: SeriesDefinition = js.native
  val HistogramSeries: SeriesDefinition = js.native
  val CrosshairMode: js.Dynamic = js.native
  val LineType: js.Dynamic = js.native

@js.native
trait SeriesDefinition extends js.Object

@js.native
trait IChartApi extends js.Object:
  def addSeries(definition: SeriesDefinition, options: js.Object, paneIndex: Int = js.native): ISeriesApi = js.native
  def applyOptions(options: js.Object): Unit = js.native
  def priceScale(id: String): IPriceScaleApi = js.native
  def timeScale(): ITimeScaleApi = js.native
  def panes(): js.Array[IPaneApi] = js.native
  def subscribeCrosshairMove(handler: js.Function1[MouseEventParams, Unit]): Unit = js.native
  def remove(): Unit = js.native

@js.native
trait ISeriesApi extends js.Object:
  def setData(data: js.Array[js.Object]): Unit = js.native
  def applyOptions(options: js.Object): Unit = js.native

@js.native
trait ISeriesMarkers extends js.Object:
  def setMarkers(markers: js.Array[js.Object]): Unit = js.native

@js.native
trait IPriceScaleApi extends js.Object:
  def applyOptions(options: js.Object): Unit = js.native

@js.native
trait ITimeScaleApi extends js.Object:
  def fitContent(): Unit = js.native
  def setVisibleRange(range: js.Object): Unit = js.native

@js.native
trait IPaneApi extends js.Object:
  def setStretchFactor(factor: Double): Unit = js.native

/** Crosshair event. `time` is the business-day string we set the data with
  * ("YYYY-MM-DD"), or undefined when the pointer leaves the chart.
  */
@js.native
trait MouseEventParams extends js.Object:
  val time: js.UndefOr[String] = js.native
