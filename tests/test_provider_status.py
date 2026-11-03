from types import SimpleNamespace

import pytest
from ytmusicapi.exceptions import YTMusicServerError
from ytmusicapi.navigation import SECTION_LIST, SINGLE_COLUMN_TAB

from radio_prototype.config import Settings
from radio_prototype.providers import Providers, ProviderUnavailable


def test_history_signin_message_is_actionable_without_a_mutation(tmp_path):
    settings = Settings(tmp_path)
    settings.youtube_file.write_text("{}")
    response = [
        {
            "itemSectionRenderer": {
                "contents": [
                    {
                        "messageRenderer": {
                            "text": {"runs": [{"text": "Sign in to view your history"}]}
                        }
                    }
                ]
            }
        }
    ]
    for key in reversed(SINGLE_COLUMN_TAB + SECTION_LIST):
        response = [response] if key == 0 else {key: response}

    def unavailable():
        raise YTMusicServerError(None)

    provider = Providers(settings)
    provider.youtube = SimpleNamespace(get_history=unavailable, _send_request=lambda *a: response)
    with pytest.raises(ProviderUnavailable, match="Reconnect YouTube"):
        provider.history()


def test_unknown_history_layout_remains_an_error(tmp_path):
    settings = Settings(tmp_path)
    settings.youtube_file.write_text("{}")

    def unavailable():
        raise YTMusicServerError("Unsupported layout")

    provider = Providers(settings)
    provider.youtube = SimpleNamespace(get_history=unavailable, _send_request=lambda *a: {})
    with pytest.raises(YTMusicServerError, match="Unsupported layout"):
        provider.history()
