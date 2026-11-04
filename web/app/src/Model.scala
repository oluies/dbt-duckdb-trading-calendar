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

  /** Index of a fixing day, for slicing the band of a regime. */
  def indexOf(date: String): Int = days.indexWhere(_.date == date)

  def color(r: Regime): String =
    val lo = vols.headOption.getOrElse(0.0)
    val hi = vols.lastOption.getOrElse(0.0)
    FxData.ramp(if hi > lo then (r.annualVolPct - lo) / (hi - lo) else 0.0)

object FxData:

  /** Low -> high volatility: the palette of docs/fx_regimes.png ("flare"),
    * ending in a brighter purple that stays visible on a dark background.
    */
  private val Ramp = Vector((0xed, 0xb0, 0x81), (0xd1, 0x4a, 0x61), (0x9a, 0x3a, 0xa8))

  def ramp(t: Double): String =
    val x = math.min(math.max(t, 0.0), 1.0) * (Ramp.size - 1)
    val i = math.min(x.toInt, Ramp.size - 2)
    val f = x - i
    val ((r0, g0, b0), (r1, g1, b1)) = (Ramp(i), Ramp(i + 1))
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
