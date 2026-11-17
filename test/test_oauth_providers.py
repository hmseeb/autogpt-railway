#!/usr/bin/env python3
"""Fixture tests for test/oauth-providers.py's extractor.

Upstream's integrations/oauth/ grew modules that are not deployer-configured
redirect-OAuth providers: device-flow handlers that ship a public client id
(codex, rmfg, stripe_link, microsoft_365_copilot), their shared base
(device_base) and helpers (microsoft_identity, refresh_failure, ...). Only a
class that subclasses BaseOAuthHandler needs a <PROVIDER>_CLIENT_ID from the
person who deployed.

    python3 test/test_oauth_providers.py
"""
import importlib.util
import pathlib
import tempfile
import unittest

HERE = pathlib.Path(__file__).parent
spec = importlib.util.spec_from_file_location("oauth_providers", HERE / "oauth-providers.py")
op = importlib.util.module_from_spec(spec)
spec.loader.exec_module(op)


def tree(files: dict[str, str]) -> pathlib.Path:
    root = pathlib.Path(tempfile.mkdtemp())
    for rel, text in files.items():
        p = root / "autogpt_platform/backend/backend" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return root


class ExtractorTest(unittest.TestCase):
    def test_only_redirect_oauth_handlers_count(self):
        root = tree({
            "integrations/oauth/__init__.py": "",
            "integrations/oauth/base.py": "class BaseOAuthHandler(ABC):\n    pass\n",
            "integrations/oauth/github.py": "class GitHubOAuthHandler(BaseOAuthHandler):\n    pass\n",
            # both kinds in one module: still a redirect provider
            "integrations/oauth/microsoft.py": (
                "class MicrosoftOAuthHandler(BaseOAuthHandler):\n    pass\n"
                "class MicrosoftDeviceAuthHandler(BaseDeviceAuthHandler):\n    pass\n"),
            "integrations/oauth/device_base.py": "class BaseDeviceAuthHandler(ABC):\n    pass\n",
            "integrations/oauth/codex.py": "class CodexDeviceAuthHandler(BaseDeviceAuthHandler):\n    pass\n",
            "integrations/oauth/refresh_failure.py": "class RefreshFailure(BaseModel):\n    pass\n",
            "integrations/oauth/github_test.py": "class X(BaseOAuthHandler):\n    pass\n",
            "blocks/linear/_config.py": 'x = ProviderBuilder("linear").with_oauth(Handler)\n',
            "blocks/wordpress/_config.py": (
                'x = ProviderBuilder("wordpress").with_oauth(H, client_id_env_var="WP_ID")\n'),
            "blocks/exa/_config.py": 'x = ProviderBuilder("exa").with_api_key("EXA_API_KEY")\n',
        })
        self.assertEqual(op.find_providers(root), {
            "github": "GITHUB_CLIENT_ID",
            "microsoft": "MICROSOFT_CLIENT_ID",
            "linear": "LINEAR_CLIENT_ID",
            "wordpress": "WP_ID",
        })


if __name__ == "__main__":
    unittest.main()
