package fxregimes

import com.raquo.laminar.api.L.*
import org.scalajs.dom
import scala.util.Try

/** The colours the chart and the regime swatches need, read from the page's
  * CSS tokens (index.html). Every palette there is checked against WCAG 2.1
  * AA: text 4.5:1, chart lines, swatches and focus rings 3:1.
  */
final case class Palette(
    bg: String,
    fg: String,
    muted: String,
    line: String,
    ramp: Vector[String],
    bandAlpha: Double
)

/** A background the reader can pick. `Auto` follows the host's data-theme
  * attribute, then the OS setting.
  */
enum Background(val key: String, val label: String):
  case Auto extends Background("auto", "Auto")
  case White extends Background("white", "White")
  case LightGrey extends Background("lightgrey", "Light grey")
  case DarkGrey extends Background("darkgrey", "Dark grey")
  case Black extends Background("black", "Black")

object Theme:

  private val StorageKey = "fx-regimes-background"
  private val root = dom.document.documentElement

  private def token(name: String): String =
    dom.window.getComputedStyle(root).getPropertyValue(name).trim

  private def read(): Palette =
    Palette(
      bg = token("--bg"),
      fg = token("--fg"),
      muted = token("--muted"),
      line = token("--line"),
      ramp = Vector(token("--ramp-0"), token("--ramp-1"), token("--ramp-2")),
      bandAlpha = token("--band-alpha").toDoubleOption.getOrElse(0.25)
    )

  private val paletteVar = Var(read())

  /** The current palette; changes with the background choice, the host's
    * data-theme and the OS light/dark setting.
    */
  val palette: Signal[Palette] = paletteVar.signal

  /** The background the reader picked, remembered in this browser if storage allows. */
  val background: Var[Background] = Var(
    Try(dom.window.localStorage.getItem(StorageKey)).toOption
      .flatMap(k => Background.values.find(_.key == k))
      .getOrElse(Background.Auto)
  )

  private def refresh(): Unit = paletteVar.set(read())

  private def apply(bg: Background): Unit =
    if bg == Background.Auto then root.removeAttribute("data-bg") else root.setAttribute("data-bg", bg.key)
    Try(dom.window.localStorage.setItem(StorageKey, bg.key))
    refresh()

  /** Wire the listeners once, for the life of the page. */
  def install(): Unit =
    apply(background.now())
    background.signal.changes.foreach(apply)(unsafeWindowOwner)
    dom.window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (_: dom.Event) => refresh())
    new dom.MutationObserver((_, _) => refresh()).observe(
      root,
      new dom.MutationObserverInit { attributes = true; attributeFilter = scala.scalajs.js.Array("data-theme") }
    )

  /** The "Background" picker: a labelled native select, so it works with a keyboard and screen readers. */
  def picker: HtmlElement =
    label(
      cls := "picker",
      "Background ",
      select(
        idAttr := "background",
        Background.values.toList.map(b => option(value := b.key, b.label)),
        controlled(
          value <-- background.signal.map(_.key),
          onChange.mapToValue.map(k => Background.values.find(_.key == k).getOrElse(Background.Auto)) --> background
        )
      )
    )
