//! La courbe du tableau de bord de démonstration, dessinée dans un `<canvas>`.
//!
//! Chaque seconde, une mesure fictive entre par la droite ; quand le point courant
//! l'atteint, les chiffres de l'écran prennent sa valeur.

use std::cell::{Cell, RefCell};
use std::rc::Rc;

use wasm_bindgen::JsCast;
use wasm_bindgen::prelude::*;
use web_sys::{CanvasRenderingContext2d, HtmlCanvasElement};

use crate::demo::{Flow, POINTS, SCALE_MAX};
use crate::islands::Readings;

// Les couleurs de public/site.css.
const DOWN: &str = "#7cd4fd";
const UP: &str = "#ffb37a";
const GRID: &str = "#1b1f35";
const LABEL: &str = "#858cab";
const BACKGROUND: &str = "#090b14";
const FONT: &str = "10px \"JetBrains Mono\", ui-monospace, monospace";

const PAD_TOP: f64 = 6.0;
const PAD_RIGHT: f64 = 7.0;
const PAD_BOTTOM: f64 = 3.0;

type FrameCallback = Closure<dyn FnMut(f64)>;

struct Chart {
    canvas: HtmlCanvasElement,
    context: CanvasRenderingContext2d,
    width: f64,
    height: f64,
}

impl Chart {
    /// Accorde la taille du canvas à sa taille à l'écran et à la densité de pixels.
    fn resize(&mut self) {
        let rect = self.canvas.get_bounding_client_rect();
        if rect.width() == self.width && rect.height() == self.height {
            return;
        }
        let ratio = web_sys::window()
            .map_or(1.0, |window| window.device_pixel_ratio())
            .clamp(1.0, 3.0);
        self.width = rect.width();
        self.height = rect.height();
        self.canvas.set_width((self.width * ratio).round() as u32);
        self.canvas.set_height((self.height * ratio).round() as u32);
        let _ = self.context.set_transform(ratio, 0.0, 0.0, ratio, 0.0, 0.0);
    }

    fn y(&self, mbps: f64) -> f64 {
        self.height - PAD_BOTTOM - (mbps / SCALE_MAX) * (self.height - PAD_TOP - PAD_BOTTOM)
    }

    /// Trace une série, décalée de `t` (0 à 1) vers la gauche.
    fn trace(&self, series: &[f64], t: f64) {
        let step = (self.width - PAD_RIGHT) / (POINTS - 1) as f64;
        self.context.begin_path();
        for (index, value) in series.iter().enumerate() {
            let x = (index as f64 - t) * step;
            if index == 0 {
                self.context.move_to(x, self.y(*value));
            } else {
                self.context.line_to(x, self.y(*value));
            }
        }
    }

    fn draw(&mut self, flow: &Flow, t: f64) {
        self.resize();
        if self.width == 0.0 {
            return;
        }
        let (width, height) = (self.width, self.height);
        let context = &self.context;
        context.clear_rect(0.0, 0.0, width, height);

        // La grille : 20 et 40 Mb/s.
        context.set_font(FONT);
        context.set_text_baseline("bottom");
        context.set_line_width(1.0);
        for mark in [20.0, 40.0] {
            let y = self.y(mark).round() + 0.5;
            context.set_stroke_style_str(GRID);
            context.begin_path();
            context.move_to(0.0, y);
            context.line_to(width, y);
            context.stroke();
            context.set_fill_style_str(LABEL);
            let _ = context.fill_text(&format!("{mark:.0}"), 0.0, y - 2.0);
        }

        context.save();
        context.begin_path();
        context.rect(0.0, 0.0, width - PAD_RIGHT, height);
        context.clip();

        // Le descendant : une aire sous un trait.
        self.trace(flow.down(), t);
        context.line_to(width + 40.0, height);
        context.line_to(-40.0, height);
        context.close_path();
        let gradient = context.create_linear_gradient(0.0, 0.0, 0.0, height);
        let _ = gradient.add_color_stop(0.0, &format!("{DOWN}55"));
        let _ = gradient.add_color_stop(1.0, &format!("{DOWN}00"));
        context.set_fill_style_canvas_gradient(&gradient);
        context.fill();

        context.set_line_join("round");
        context.set_line_cap("round");
        context.set_line_width(2.0);
        self.trace(flow.down(), t);
        context.set_stroke_style_str(DOWN);
        context.stroke();
        context.set_line_width(1.5);
        self.trace(flow.up(), t);
        context.set_stroke_style_str(UP);
        context.stroke();
        context.restore();

        // Les points courants, sur le bord droit.
        for (series, color, radius) in [(flow.down(), DOWN, 3.5), (flow.up(), UP, 3.0)] {
            let last = series.len() - 1;
            let value = series[last - 1] + (series[last] - series[last - 1]) * t;
            context.begin_path();
            let _ = context.arc(
                width - PAD_RIGHT,
                self.y(value),
                radius,
                0.0,
                std::f64::consts::TAU,
            );
            context.set_fill_style_str(color);
            context.fill();
            context.set_line_width(2.0);
            context.set_stroke_style_str(BACKGROUND);
            context.stroke();
        }
    }

    /// Si le canvas est à l'écran : inutile de dessiner ce que personne ne voit.
    fn on_screen(&self) -> bool {
        let rect = self.canvas.get_bounding_client_rect();
        let viewport = web_sys::window()
            .and_then(|window| window.inner_height().ok())
            .and_then(|height| height.as_f64())
            .unwrap_or(f64::MAX);
        rect.bottom() > 0.0 && rect.top() < viewport
    }
}

fn reduced_motion() -> bool {
    web_sys::window()
        .and_then(|window| {
            window
                .match_media("(prefers-reduced-motion: reduce)")
                .ok()
                .flatten()
        })
        .is_some_and(|query| query.matches())
}

/// Démarre la démonstration dans `canvas`. La fonction renvoyée l'arrête.
pub fn start(canvas: &web_sys::Element, readings: Readings) -> impl FnOnce() + use<> {
    let running = Rc::new(Cell::new(true));
    let stop = running.clone();
    let cleanup = move || stop.set(false);

    let Some(canvas) = canvas.dyn_ref::<HtmlCanvasElement>().cloned() else {
        return cleanup;
    };
    let Some(context) = canvas
        .get_context("2d")
        .ok()
        .flatten()
        .and_then(|context| context.dyn_into::<CanvasRenderingContext2d>().ok())
    else {
        return cleanup;
    };
    let seed = js_sys::Date::now() as u64 as u32;
    let mut flow = Flow::new(seed);
    let mut chart = Chart {
        canvas,
        context,
        width: 0.0,
        height: 0.0,
    };
    // L'image de repos : la dernière mesure est à l'écran.
    chart.draw(&flow, 1.0);
    if reduced_motion() {
        return cleanup;
    }

    // La mesure suivante entre par la droite pendant la seconde qui vient.
    flow.step();
    let mut second_started: Option<f64> = None;
    let slot: Rc<RefCell<Option<FrameCallback>>> = Rc::new(RefCell::new(None));
    let again = slot.clone();
    let request = |callback: &FrameCallback| {
        if let Some(window) = web_sys::window() {
            let _ = window.request_animation_frame(callback.as_ref().unchecked_ref());
        }
    };
    *slot.borrow_mut() = Some(Closure::new(move |now: f64| {
        if !running.get() {
            again.borrow_mut().take();
            return;
        }
        let started = *second_started.get_or_insert(now);
        let mut t = (now - started) / 1000.0;
        if t >= 1.0 {
            // Le point courant vient d'atteindre la mesure : les chiffres la prennent.
            let (down, up) = flow.latest();
            readings.down.set(down);
            readings.up.set(up);
            readings.latency.set(flow.latency());
            readings.jitter.set(flow.jitter());
            flow.step();
            second_started = Some(now);
            t = 0.0;
        }
        if chart.on_screen() {
            chart.draw(&flow, t);
        }
        if let Some(callback) = again.borrow().as_ref() {
            request(callback);
        }
    }));
    if let Some(callback) = slot.borrow().as_ref() {
        request(callback);
    }
    cleanup
}
