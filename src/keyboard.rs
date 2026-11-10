//! A tiny Wayland virtual keyboard that presses Ctrl+V with real key codes.
//!
//! wtype gives every key a made-up code. Simple text boxes don't care, but
//! apps that look at the key code (Electron apps like Claude) can miss it.
//! Here the keys sit where they are on a US keyboard, so apps see a normal one.

use std::{
    io::Write,
    os::fd::{AsFd, FromRawFd, OwnedFd},
    time::Instant,
};

use anyhow::{Context, Result, bail};
use wayland_client::{
    Connection, Dispatch, QueueHandle,
    globals::{GlobalListContents, registry_queue_init},
    protocol::{wl_registry::WlRegistry, wl_seat::WlSeat},
};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1, zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1,
};

/// (evdev key, normal keysym, shifted keysym) for a US layout.
const US: &[(u32, &str, &str)] = &[
    (2, "1", "exclam"),
    (3, "2", "at"),
    (4, "3", "numbersign"),
    (5, "4", "dollar"),
    (6, "5", "percent"),
    (7, "6", "asciicircum"),
    (8, "7", "ampersand"),
    (9, "8", "asterisk"),
    (10, "9", "parenleft"),
    (11, "0", "parenright"),
    (12, "minus", "underscore"),
    (13, "equal", "plus"),
    (15, "Tab", "Tab"),
    (16, "q", "Q"),
    (17, "w", "W"),
    (18, "e", "E"),
    (19, "r", "R"),
    (20, "t", "T"),
    (21, "y", "Y"),
    (22, "u", "U"),
    (23, "i", "I"),
    (24, "o", "O"),
    (25, "p", "P"),
    (26, "bracketleft", "braceleft"),
    (27, "bracketright", "braceright"),
    (30, "a", "A"),
    (31, "s", "S"),
    (32, "d", "D"),
    (33, "f", "F"),
    (34, "g", "G"),
    (35, "h", "H"),
    (36, "j", "J"),
    (37, "k", "K"),
    (38, "l", "L"),
    (39, "semicolon", "colon"),
    (40, "apostrophe", "quotedbl"),
    (41, "grave", "asciitilde"),
    (43, "backslash", "bar"),
    (44, "z", "Z"),
    (45, "x", "X"),
    (46, "c", "C"),
    (47, "v", "V"),
    (48, "b", "B"),
    (49, "n", "N"),
    (50, "m", "M"),
    (51, "comma", "less"),
    (52, "period", "greater"),
    (53, "slash", "question"),
    (57, "space", "space"),
];

const SHIFT_KEY: u32 = 42;
const CTRL_KEY: u32 = 29;
const CTRL: u32 = 4;
/// A plain US keymap.
fn keymap() -> String {
    let mut codes = String::new();
    let mut syms = String::new();
    let mut add = |key: u32, sym: String| {
        let x = key + 8;
        codes.push_str(&format!("  <K{x}> = {x};\n"));
        syms.push_str(&format!("  key <K{x}> {{ [ {sym} ] }};\n"));
    };
    for &(key, low, high) in US {
        add(key, if low == high { low.to_owned() } else { format!("{low}, {high}") });
    }
    add(SHIFT_KEY, "Shift_L".into());
    add(CTRL_KEY, "Control_L".into());
    format!(
        "xkb_keymap {{\n\
         xkb_keycodes \"dictate\" {{\n  minimum = 8;\n  maximum = 255;\n{codes}}};\n\
         xkb_types \"dictate\" {{ include \"complete\" }};\n\
         xkb_compat \"dictate\" {{ include \"complete\" }};\n\
         xkb_symbols \"dictate\" {{\n{syms}  modifier_map Shift {{ <K{}> }};\n  modifier_map Control {{ <K{}> }};\n}};\n\
         }};\n",
        SHIFT_KEY + 8,
        CTRL_KEY + 8
    )
}

struct State;

impl Dispatch<WlRegistry, GlobalListContents> for State {
    fn event(_: &mut Self, _: &WlRegistry, _: <WlRegistry as wayland_client::Proxy>::Event, _: &GlobalListContents, _: &Connection, _: &QueueHandle<Self>) {}
}
wayland_client::delegate_noop!(State: ignore WlSeat);
wayland_client::delegate_noop!(State: ZwpVirtualKeyboardManagerV1);
wayland_client::delegate_noop!(State: ZwpVirtualKeyboardV1);

struct Keyboard {
    conn: Connection,
    queue: wayland_client::EventQueue<State>,
    vk: ZwpVirtualKeyboardV1,
    start: Instant,
    mods: u32,
}

impl Keyboard {
    fn open() -> Result<Self> {
        let conn = Connection::connect_to_env().context("no Wayland session")?;
        let (globals, queue) = registry_queue_init::<State>(&conn).context("Wayland registry failed")?;
        let qh = queue.handle();
        let seat: WlSeat = globals.bind(&qh, 1..=7, ()).context("no Wayland seat")?;
        let manager: ZwpVirtualKeyboardManagerV1 =
            globals.bind(&qh, 1..=1, ()).context("the compositor has no virtual keyboard support")?;
        let vk = manager.create_virtual_keyboard(&seat, &qh, ());
        Ok(Self { conn, queue, vk, start: Instant::now(), mods: 0 })
    }

    fn load(&mut self) -> Result<()> {
        let text = keymap();
        let fd = unsafe {
            let raw = libc::memfd_create(c"dictate-keymap".as_ptr(), libc::MFD_CLOEXEC);
            if raw < 0 {
                bail!("memfd_create failed");
            }
            OwnedFd::from_raw_fd(raw)
        };
        let mut file = std::fs::File::from(fd);
        file.write_all(text.as_bytes())?;
        file.write_all(&[0])?;
        // 1 = xkb v1 keymap.
        self.vk.keymap(1, file.as_fd(), text.len() as u32 + 1);
        self.sync()
    }

    fn sync(&mut self) -> Result<()> {
        self.queue.roundtrip(&mut State).context("Wayland connection lost")?;
        Ok(())
    }

    fn set_mods(&mut self, mods: u32) {
        if self.mods != mods {
            self.vk.modifiers(mods, 0, 0, 0);
            self.mods = mods;
        }
    }

    fn tap(&mut self, key: u32, mods: u32) -> Result<()> {
        self.set_mods(mods);
        let t = self.start.elapsed().as_millis() as u32;
        self.vk.key(t, key, 1);
        self.vk.key(t, key, 0);
        self.sync()
    }

    fn close(mut self) -> Result<()> {
        self.set_mods(0);
        self.vk.destroy();
        self.conn.flush().ok();
        self.sync()
    }
}

/// Ctrl+V, on the real V key.
pub fn paste_keys() -> Result<()> {
    let mut kb = Keyboard::open()?;
    kb.load()?;
    kb.tap(47, CTRL)?;
    kb.close()
}
