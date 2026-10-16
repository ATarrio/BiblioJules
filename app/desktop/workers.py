"""Run the app's async helpers off the Qt GUI thread.

``lookup_isbn`` and ``search_books`` are ``async`` functions that use httpx.
Qt runs its own event loop, so we hand the coroutine to a worker thread with
:class:`QThreadPool` and marshal the result back with Qt signals.
"""

from __future__ import annotations

import asyncio
from typing import Any, Callable

from PySide6.QtCore import QObject, QRunnable, QThreadPool, Signal, Slot


class _WorkerSignals(QObject):
    finished = Signal(object)  # the coroutine's return value
    error = Signal(str)  # exception message


class _AsyncRunnable(QRunnable):
    def __init__(self, func: Callable[..., Any], args: tuple, kwargs: dict) -> None:
        super().__init__()
        self._func = func
        self._args = args
        self._kwargs = kwargs
        self.signals = _WorkerSignals()

    @Slot()
    def run(self) -> None:  # runs on a QThreadPool thread
        try:
            result = asyncio.run(self._func(*self._args, **self._kwargs))
        except Exception as exc:  # noqa: BLE001 - surface any failure to the UI
            self.signals.error.emit(str(exc))
        else:
            self.signals.finished.emit(result)


# Keep strong references to running jobs; QThreadPool deletes the C++ side
# after the run, but we still need the Python wrapper alive for the signals.
_active: set[_AsyncRunnable] = set()


def run_async(
    func: Callable[..., Any],
    on_done: Callable[[Any], None],
    on_error: Callable[[str], None] | None = None,
    *args: Any,
    **kwargs: Any,
) -> _AsyncRunnable:
    """Run ``func(*args, **kwargs)`` in a worker thread.

    ``func`` must be an ``async`` callable. ``on_done`` receives the result;
    ``on_error`` (optional) receives an error message string.
    """
    runnable = _AsyncRunnable(func, args, kwargs)
    _active.add(runnable)
    runnable.signals.finished.connect(on_done)
    if on_error is not None:
        runnable.signals.error.connect(on_error)

    def _cleanup(*_: Any) -> None:
        _active.discard(runnable)

    runnable.signals.finished.connect(_cleanup)
    runnable.signals.error.connect(_cleanup)

    QThreadPool.globalInstance().start(runnable)
    return runnable
