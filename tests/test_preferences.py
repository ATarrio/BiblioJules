"""Preferences survive concurrent changes and keep unrelated keys."""

from __future__ import annotations

from app import preferences, themes
from app.services.jsonstore import load_json, save_json, update_json_object


def test_preferences_preserve_unknown_keys(tmp_path, monkeypatch):
    path = tmp_path / "preferences.json"
    monkeypatch.setattr(preferences, "PREFS_FILE", path)
    save_json(path, {"language": "en", "custom": "keep me"})

    preferences.set_color_theme(themes.DEFAULT_THEME)

    data = load_json(path, {})
    assert data["custom"] == "keep me"
    assert data["color_theme"] == themes.DEFAULT_THEME


def test_update_json_object_ignores_a_corrupt_file(tmp_path):
    path = tmp_path / "broken.json"
    path.write_text("{not json", encoding="utf-8")

    update_json_object(path, lambda data: data.update(ok=True))

    assert load_json(path, {}) == {"ok": True}
