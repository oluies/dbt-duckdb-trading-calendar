package fxregimes

import com.raquo.laminar.api.L.*

/** "How the regimes are found": the queries behind the chart and what each
  * parameter means. Figures that depend on the data (N, ln N, the penalty,
  * the median volatility) are computed from it, not written in.
  */
object Explainer:

  private val Repo = "https://github.com/oluies/dbt-duckdb-trading-calendar/blob/main/"

  // cost 'normal' has p = 2 parameters per segment (mean and variance).
  private val NormalParams = 2
  private val MinRegimeDays = 20
  private val TradingDaysPerYear = 252

  def view(fx: FxData): HtmlElement =
    val n = fx.days.count(_.ret.isDefined)
    val lnN = math.log(n.toDouble)
    val vols = fx.regimes.map(_.annualVolPct).sorted
    val median = (vols((vols.size - 1) / 2) + vols(vols.size / 2)) / 2

    sectionTag(
      cls := "explainer",
      h2("How the regimes are found"),
      p(
        "The page shows the output of a fetch script and three dbt models. Each step below gives the query (simplified from the model ",
        "or script) and what its parameters mean."
      ),
      step(
        "1. Getting the data",
        "scripts/fetch_riksbank_fx.py",
        s"""-- The API answers DuckDB's HEAD probe with 404; a plain GET works.
SET force_download = true;

COPY (
    SELECT date::DATE             AS rate_date,
           value::DECIMAL(10, 4)  AS sek_per_eur
    FROM read_json('https://api.riksbank.se/swea/v1/Observations/SEKEURPMI/2015-01-01/${fx.days.last.date}')
    ORDER BY rate_date
) TO 'seeds/riksbank_sekeur.csv' (HEADER)""",
        div(
          p(
            "The series comes from the Riksbank's open data API, SWEA, which needs no key. Series SEKEURPMI is the ",
            "daily SEK/EUR fixing, published on Swedish banking days. DuckDB reads the JSON response over HTTPS with ",
            code("read_json"), " and writes it to a CSV file."
          ),
          p(
            "That CSV is a dbt seed, a frozen copy committed to the repository, so builds and CI never call the ",
            "rate-limited API. From there the data flows:"
          ),
          ol(
            li("the fetch script writes ", code("seeds/riksbank_sekeur.csv"), ";"),
            li(code("dbt seed"), " loads it, and ", code("dbt build --vars '{with_changepoint: true}'"),
              " runs the three models below into SQL Server;"),
            li(code("scripts/export_fx_regimes_json.py"), " reads the results back and writes ", code("fx_regimes.json"), ";"),
            li("this page fetches that file when it loads.")
          ),
          p(f"The copy on this page ends on ${fx.days.last.date}, with ${fx.days.size}%,d fixings.")
        )
      ),
      step(
        "2. Daily returns",
        "models/changepoint/stg_riksbank_fx.sql",
        """select rate_date,
       sek_per_eur,
       100 * ln(sek_per_eur / lag(sek_per_eur) over (order by rate_date)) as log_return_pct
from riksbank_sekeur""",
        p(
          "The exchange rate itself drifts, so the detector works on the log return between consecutive fixings, ",
          "in percent. A return of +0.50 means the krona weakened by about half a percent against the euro since ",
          f"the previous fixing. That gives N = $n%,d returns from ${fx.days(1).date} to ${fx.days.last.date}."
        )
      ),
      step(
        "3. Trading-day index",
        "models/changepoint/fct_trading_day_fx.sql",
        """select d.date_day,
       coalesce(x.is_trading_day, true) as is_xsto_trading_day,  -- NULL in years the calendar does not cover
       fx.rate_date is not null          as has_fixing
from dim_date d
left join fct_exchange_calendar x on x.calendar_date = d.date_day and x.exchange_code = 'XSTO'
left join stg_riksbank_fx fx      on fx.rate_date    = d.date_day
where not d.is_weekend""",
        p(
          "The returns are indexed by trading day rather than calendar day, using the project's date dimension and the ",
          "Nasdaq Stockholm (XSTO) exception calendar. A dbt test checks that the Riksbank publishes on exactly the XSTO ",
          "trading days in the years the calendar covers. That is how the calendar's New Year's Eve error was found."
        )
      ),
      step(
        "4. Change point detection",
        "models/changepoint/fct_fx_regimes.sql",
        s"""with series as (
    select list(log_return_pct order by date_day) as xs,
           list(date_day       order by date_day) as days
    from fct_trading_day_fx
    where log_return_pct is not null
)
select days[seg.start]           as start_date,
       days[seg."end"]           as end_date,
       seg.n                     as trading_days,
       seg.mean                  as mean_log_return_pct,
       sqrt(seg.var)             as daily_vol_pct,
       sqrt(seg.var * $TradingDaysPerYear)       as annualised_vol_pct
from (select days, unnest(cpt_segment_stats(xs, cpt_pelt(xs, 'normal', 'mbic', $MinRegimeDays))) as seg
      from series)""",
        p(
          "The returns go into one list in date order, with a matching list of dates. ",
          code("cpt_pelt"), " returns the positions where segments end, ", code("cpt_segment_stats"),
          " gives each segment's start, end, length, mean and variance, ", code("unnest"),
          " makes one row per regime, and indexing the date list turns positions back into dates."
        )
      ),
      h3("The parameters"),
      dl(
        term(code("cpt_pelt"), " (the algorithm)"),
        dd(
          "PELT (Killick, Fearnhead and Eckley, 2012) finds the segmentation that minimises the total cost of ",
          "the segments plus a penalty for each change point. It is exact: it returns the same answer as checking ",
          "every possible segmentation, but prunes candidates that can no longer win, so it runs in roughly linear time."
        ),
        term(code("'normal'"), " (the cost)"),
        dd(
          "Each regime is modelled as normally distributed returns with its own mean and its own variance. A segment ",
          "of n returns with sample variance σ̂² costs n · ln σ̂², which is −2 × the log-likelihood up to a constant. ",
          "So a split pays off when the two parts have clearly different volatility (or mean). FX returns keep a mean ",
          "near zero, so in practice the breaks here are changes in volatility."
        ),
        term(code("'mbic'"), " (the penalty)"),
        dd(
          f"Each change point must improve the fit by more than a penalty β. MBIC, the default in R's changepoint package, uses ",
          f"β = (p + 2) · ln N with p = $NormalParams parameters per segment: 4 · ln $n%,d ≈ ${4 * lnN}%.1f. It also adds ln nᵢ ",
          f"for every segment of length nᵢ, which makes very short regimes harder to justify. For comparison, ",
          f"'bic' uses (p + 1) · ln N ≈ ${3 * lnN}%.1f and 'aic' uses 2(p + 1) = 6. A larger penalty gives fewer regimes."
        ),
        term(code(MinRegimeDays.toString), " (minimum regime length)"),
        dd(
          s"No regime may be shorter than $MinRegimeDays trading days, about a month. This stops a single wild week ",
          "from becoming a regime of its own. The dbt variables cpt_penalty and cpt_min_regime_days set both values."
        )
      ),
      h3("The table and the chart"),
      dl(
        term("Trading days"),
        dd("The number of daily returns in the regime."),
        term("Mean return %"),
        dd("The average daily log return in the regime. Close to zero for every regime."),
        term("Daily vol %"),
        dd("The sample standard deviation of the daily returns: a typical day's move."),
        term("Annualised vol %"),
        dd(
          s"Daily volatility × √$TradingDaysPerYear, the usual way to quote volatility per year. It also sets each regime's colour, ",
          "from light (calm) to purple (stressed)."
        ),
        term("±2σ band"),
        dd(
          "In the lower pane: the regime mean ± 2 × daily volatility. If the returns were normal, about 95% of days ",
          "would fall inside it."
        ),
        term("Stress regimes"),
        dd(
          f"Regimes with at least twice the median regime volatility (median ${median}%.1f%%, so at least ${2 * median}%.1f%%), ",
          "marked with an arrow and labelled. A dbt test requires the COVID sell-off (2020-03-16) and the April 2025 ",
          "tariff shock (2025-04-07) to fall in such regimes."
        )
      )
    )

  private def step(title: String, model: String, sql: String, body: HtmlElement): HtmlElement =
    div(
      cls := "step",
      h3(title),
      body,
      pre(code(sql)),
      p(cls := "source", "Source: ", a(href := Repo + model, model))
    )

  private def term(mods: Modifier[HtmlElement]*): HtmlElement = dt(mods)
