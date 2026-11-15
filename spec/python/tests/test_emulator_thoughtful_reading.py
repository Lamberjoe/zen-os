import os
import tempfile
import time
from pathlib import Path

import pytest

from zen_driver import ZenDriver, launch, stop, wait_for_socket
from test_emulator_reader_tools import _write_reader_epub


pytestmark = pytest.mark.skipif(
    os.environ.get("ZEN_UI_RUN_EMULATOR") != "1", reason="requires the KOReader emulator"
)


def _capture(driver, name):
    output = Path(__file__).resolve().parents[2] / ".artifacts" / "thoughtful_reading" / name
    output.parent.mkdir(parents=True, exist_ok=True)
    driver.screenshot(output)
    return output


def _tr(driver: ZenDriver, action="state"):
    result = driver.command("thoughtful_reading_action", action=action)
    assert result["ok"], result
    return result["thoughtful_reading"]


def _run(enabled: bool, check) -> None:
    with tempfile.TemporaryDirectory(prefix="zen-thoughtful-reading-") as temporary:
        root = Path(temporary)
        library = root / "library"
        library.mkdir()
        book = library / "questions.epub"
        _write_reader_epub(book)
        socket = root / "driver.sock"
        config = "return { updater = { update_auto_check = false }, features = { thoughtful_reading = %s } }\n" % (
            "true" if enabled else "false")
        process = launch(Path(os.environ["KOREADER_DIR"]), root / "home", socket, library, zen_config_source=config)
        try:
            wait_for_socket(socket)
            driver = ZenDriver(socket)
            check(driver, book)
        finally:
            stop(process)


def _open_book(driver: ZenDriver, book: Path) -> None:
    assert driver.open_book(book)["ok"]
    deadline = time.monotonic() + 30
    while not driver.command("reader_state").get("reader", {}).get("open"):
        assert time.monotonic() < deadline, "reader did not open"
        time.sleep(0.1)


def test_questions_in_the_library_and_the_reader():
    def check(driver, book):
        state = _tr(driver)
        assert state["enabled"] and state["library"]
        _open_book(driver, book)
        assert _tr(driver)["reader"]
        assert _tr(driver, "ask")["card"]
        _capture(driver, "question-card.png")
        assert not _tr(driver, "close")["card"]

    _run(True, check)


def test_switched_off_adds_nothing():
    def check(driver, book):
        assert not _tr(driver)["library"]
        _open_book(driver, book)
        state = _tr(driver)
        assert not state["enabled"] and not state["reader"]

    _run(False, check)
