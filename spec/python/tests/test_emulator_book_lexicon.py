import os
import tempfile
import time
import zipfile
from pathlib import Path

import pytest

from zen_driver import ZenDriver, launch, stop, wait_for_socket


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires the KOReader emulator"
)

LEXICON = """# Lexicon Fixture

## Ciaphas Cain
Kind: Person
Also: Cain
Rank: Commissar
→ Friend: Jurgen

- Hero of the Imperium.

## Jurgen
Kind: Person
→ Friend: Ciaphas Cain
"""


def _write_book(path: Path) -> None:
    paragraph = "Ciaphas Cain looked at Jurgen and sighed. " * 400
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("mimetype", "application/epub+zip", compress_type=zipfile.ZIP_STORED)
        archive.writestr("META-INF/container.xml", """<container version="1.0"
          xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>
          <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
          </rootfiles></container>""")
        archive.writestr("content.opf", """<package version="3.0" unique-identifier="id"
          xmlns="http://www.idpf.org/2007/opf"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
          <dc:identifier id="id">zen-lexicon</dc:identifier><dc:title>Lexicon Fixture</dc:title>
          <dc:language>en</dc:language></metadata><manifest>
          <item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/>
          </manifest><spine><itemref idref="chapter"/></spine></package>""")
        archive.writestr("chapter.xhtml", "<html xmlns='http://www.w3.org/1999/xhtml'><head><title>One</title>"
                         f"</head><body><h1>One</h1><p>{paragraph}</p></body></html>")


def _capture(driver, name):
    output = Path(__file__).resolve().parents[2] / ".artifacts" / "book_lexicon" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    driver.screenshot(output)
    return output


def _lexicon(driver: ZenDriver, action="state", **params):
    result = driver.command("lexicon_action", action=action, **params)
    assert result["ok"], result
    return result["lexicon"]


def _open(root: Path, enabled: bool):
    library = root / "library"
    library.mkdir()
    book = library / "lexicon.epub"
    _write_book(book)
    home = root / "home"
    folder = home / "lexicon" / "Books" / "Lexicon Fixture"
    folder.mkdir(parents=True)
    (folder / "lexicon.md").write_text(LEXICON, encoding="utf-8")
    socket = root / "driver.sock"
    config = "return { updater = { update_auto_check = false }, features = { book_lexicon = %s } }\n" % (
        "true" if enabled else "false")
    process = launch(Path(os.environ["KOREADER_DIR"]), home, socket, library, zen_config_source=config)
    wait_for_socket(socket)
    driver = ZenDriver(socket)
    assert driver.open_book(book)["ok"]
    deadline = time.monotonic() + 30
    while not driver.command("reader_state").get("reader", {}).get("open"):
        assert time.monotonic() < deadline, "reader did not open"
        time.sleep(0.1)
    return process, driver


def test_lexicon_box_window_and_card_lookup():
    with tempfile.TemporaryDirectory(prefix="zen-lexicon-") as temporary:
        process, driver = _open(Path(temporary), True)
        try:
            state = _lexicon(driver)
            assert state["enabled"] and state["registered"]
            assert state["cards"] == 2
            box = state.get("box")
            assert box and box["w"] > 0 and box["h"] > 0
            _capture(driver, "status-bar.png")
            # a pin: its box comes first, the lexicon box moves right of it
            assert driver.command("reference_action", action="pin", page=1)["ok"]
            with_pin = _lexicon(driver).get("box")
            assert with_pin and with_pin["x"] >= box["x"] and with_pin["w"] == box["w"]
            _capture(driver, "status-bar-with-pin.png")
            assert _lexicon(driver, "tap_box")["corner"]
            _capture(driver, "pins-and-lexicon.png")
            assert not _lexicon(driver, "close")["corner"]
            assert _lexicon(driver, "lookup", word="Jurgen").get("card") == "Jurgen"
            _capture(driver, "card.png")
            assert _lexicon(driver, "close").get("card") is None
            # a full-screen lexicon page keeps sideways swipes away from the book,
            # but a swipe down from the top edge still opens the reader's menu
            start = _lexicon(driver, "new_card")
            assert start["page"]
            for direction in ("west", "east", "north", "south"):
                after = _lexicon(driver, "swipe", direction=direction)
                assert after["page"] and after["book_page"] == start["book_page"], direction
            assert _lexicon(driver, "swipe", direction="south", y=5)["menu"]
            closed = _lexicon(driver, "close")
            assert not closed["page"] and not closed["menu"]
            # another name of a card finds it too
            assert _lexicon(driver, "lookup", word="Cain").get("card") == "Ciaphas Cain"
            _lexicon(driver, "close")
        finally:
            stop(process)


def test_lexicon_switched_off_leaves_the_reader_alone():
    with tempfile.TemporaryDirectory(prefix="zen-lexicon-off-") as temporary:
        process, driver = _open(Path(temporary), False)
        try:
            state = _lexicon(driver)
            assert not state["enabled"] and not state["registered"]
            assert state.get("box") is None
            assert _lexicon(driver, "lookup", word="Jurgen").get("card") is None
        finally:
            stop(process)
