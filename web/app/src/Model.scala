package fxregimes

import scala.scalajs.js

/** One Riksbank fixing day. `ret` is the log return in percent against the
  * previous fixing; the first fixing has none.
  */
final case class Day(date: String, rate: Double, ret: Option[Double])

/** One row of fct_fx_regimes. Dates are ISO strings, so they compare as text. */
final case class Regime(
    n: Int,
    start: String,
    end: String,
    tradingDays: Int,
    meanPct: Double,
    dailyVolPct: Double,
    annualVolPct: Double
):
  def contains(date: String): Boolean = date >= start && date <= end

final case class FxData(days: Vector[Day], regimes: Vector[Regime]):

  private val vols = regimes.map(_.annualVolPct).sorted
  private val medianVol =
    if vols.isEmpty then 0.0
    else if vols.size % 2 == 1 then vols(vols.size / 2)
    else (vols(vols.size / 2 - 1) + vols(vols.size / 2)) / 2

  /** Same rule as tests/assert_fx_stress_dates_in_high_vol_regimes.sql. */
  def isStress(r: Regime): Boolean = r.annualVolPct >= 2 * medianVol

  def regimeOf(date: String): Option[Regime] = regimes.find(_.contains(date))

  /** The regime of every day, in one walk over the two sorted lists. The first
    * fixing has no return and so no regime; it takes the first regime's, which
    * starts the band at the left edge of the chart.
    */
  lazy val regimeOfDay: Vector[Regime] =
    var i = 0
    days.map { d =>
      while i < regimes.size - 1 && d.date > regimes(i).end do i += 1
      regimes(i)
    }

  /** The fixing days that have a return, in the order the detector sees them. */
  lazy val returnDays: Vector[Day] = days.filter(_.ret.isDefined)

  /** Index of a fixing day, for slicing the band of a regime. */
  def indexOf(date: String): Int = days.indexWhere(_.date == date)

  /** Where the regime's volatility sits between the calmest (0) and the most volatile (1) regime. */
  def intensity(r: Regime): Double =
    val lo = vols.headOption.getOrElse(0.0)
    val hi = vols.lastOption.getOrElse(0.0)
    if hi > lo then (r.annualVolPct - lo) / (hi - lo) else 0.0

  /** The regime's colour on the palette's low -> high volatility ramp. */
  def color(r: Regime, ramp: Vector[String]): String = FxData.ramp(ramp, intensity(r))

object FxData:

  private def rgb(hex: String): (Int, Int, Int) =
    val h = hex.stripPrefix("#")
    (Integer.parseInt(h.substring(0, 2), 16), Integer.parseInt(h.substring(2, 4), 16), Integer.parseInt(h.substring(4, 6), 16))

  /** Linear interpolation along `stops` (hex colours) at t in [0, 1]. */
  def ramp(stops: Vector[String], t: Double): String =
    val x = math.min(math.max(t, 0.0), 1.0) * (stops.size - 1)
    val i = math.min(x.toInt, stops.size - 2)
    val f = x - i
    val ((r0, g0, b0), (r1, g1, b1)) = (rgb(stops(i)), rgb(stops(i + 1)))
    def mix(a: Int, b: Int) = math.round(a + (b - a) * f).toInt
    f"#${mix(r0, r1)}%02x${mix(g0, g1)}%02x${mix(b0, b1)}%02x"

  /** Parses fx_regimes.json, written by scripts/export_fx_regimes_json.py:
    * {"days": [[date, rate, return|null], ...], "regimes": [{...}, ...]}.
    */
  def parse(json: String): FxData =
    val root = js.JSON.parse(json)
    val days = root.days.asInstanceOf[js.Array[js.Array[js.Any]]].toVector.map { row =>
      val ret = row(2)
      Day(
        row(0).asInstanceOf[String],
        row(1).asInstanceOf[Double],
        if ret == null then None else Some(ret.asInstanceOf[Double])
      )
    }
    val regimes = root.regimes.asInstanceOf[js.Array[js.Dynamic]].toVector.map { r =>
      Regime(
        r.n.asInstanceOf[Int],
        r.start.asInstanceOf[String],
        r.end.asInstanceOf[String],
        r.trading_days.asInstanceOf[Int],
        r.mean_log_return_pct.asInstanceOf[Double],
        r.daily_vol_pct.asInstanceOf[Double],
        r.annualised_vol_pct.asInstanceOf[Double]
      )
    }
    FxData(days, regimes)
