"""Error handling.

Every error returned to the client uses one shape so the frontend's
`ApiError` can parse it uniformly: { code, message, details? }.
"""

from __future__ import annotations

import logging

from fastapi import FastAPI, Request
from fastapi.encoders import jsonable_encoder
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

_logger = logging.getLogger("manhwamaniacs.errors")


class AppError(Exception):
    """Raised by services/routes for expected, client-facing failures."""

    def __init__(
        self,
        message: str,
        *,
        code: str = "app_error",
        status_code: int = 400,
        details: object | None = None,
    ) -> None:
        super().__init__(message)
        self.message = message
        self.code = code
        self.status_code = status_code
        self.details = details


def _envelope(status_code: int, code: str, message: str, details: object | None = None):
    body: dict = {"code": code, "message": message}
    if details is not None:
        body["details"] = details
    return JSONResponse(status_code=status_code, content=body)


def _validation_details(errors) -> list[dict]:
    """Pydantic's errors without the value that failed, safe to serialize.

    ``input`` is dropped. It echoes the request back: a rejected password in
    the 422 body, a 2 MB OCR upload returned in full, and a lone surrogate
    (``"\\ud800"`` is valid JSON) that cannot be encoded as UTF-8, so the
    response itself raised and the client got a 500 in place of a 422.
    ``ctx`` can carry the raised exception object, which only
    ``jsonable_encoder`` knows how to render.
    """
    details = []
    for error in errors:
        item = {key: value for key, value in error.items() if key != "input"}
        if isinstance(item.get("ctx"), dict):
            item["ctx"] = {key: str(value) for key, value in item["ctx"].items()}
        details.append(item)
    return _encodable(jsonable_encoder(details))


def _encodable(value):
    """``value`` with every string made UTF-8 encodable.

    A ``loc`` can name a body key the client chose and a ``msg`` can quote the
    value a validator refused, so dropping ``input`` alone does not guarantee
    the envelope renders.
    """
    if isinstance(value, str):
        return value.encode("utf-8", "backslashreplace").decode("utf-8")
    if isinstance(value, list):
        return [_encodable(item) for item in value]
    if isinstance(value, dict):
        return {_encodable(key): _encodable(item) for key, item in value.items()}
    return value


def register_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(AppError)
    async def _app_error(_: Request, exc: AppError):
        return _envelope(exc.status_code, exc.code, exc.message, exc.details)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_: Request, exc: RequestValidationError):
        return _envelope(
            422, "validation_error", "Invalid request.", _validation_details(exc.errors())
        )

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_: Request, exc: StarletteHTTPException):
        return _envelope(exc.status_code, "http_error", str(exc.detail))

    @app.exception_handler(Exception)
    async def _unexpected(request: Request, exc: Exception):
        # Log the full traceback server-side for debugging, but never leak
        # internals to the client — they only get a generic message.
        _logger.exception(
            "Unhandled error on %s %s", request.method, request.url.path
        )
        return _envelope(500, "internal_error", "An unexpected error occurred.")
