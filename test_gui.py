#!/usr/bin/env python3
"""
Test script for lyrics_fetcher_gui.py
Verifies that the GUI can be instantiated and basic UI elements are present.
"""

import sys
from pathlib import Path

# Add parent directory to path for imports
sys.path.insert(0, str(Path(__file__).parent))


def test_gui_imports():
    """Test that all necessary imports work."""
    print("Testing imports...")
    try:
        import customtkinter as ctk

        print("✓ customtkinter imported successfully")
    except ImportError as e:
        print(f"✗ Failed to import customtkinter: {e}")
        return False

    try:
        import lyrics_fetcher_gui

        print("✓ lyrics_fetcher_gui imported successfully")
    except Exception as e:
        print(f"✗ Failed to import lyrics_fetcher_gui: {e}")
        return False

    return True


def test_gui_instantiation():
    """Test that the GUI can be instantiated."""
    print("\nTesting GUI instantiation...")
    try:
        from lyrics_fetcher_gui import LyricsFetcherGUI

        # Create the GUI instance
        app = LyricsFetcherGUI()
        print("✓ GUI instance created successfully")

        # Verify basic attributes exist
        assert hasattr(app, "title_var"), "Missing title_var"
        assert hasattr(app, "artist_var"), "Missing artist_var"
        assert hasattr(app, "album_var"), "Missing album_var"
        assert hasattr(app, "title_entry"), "Missing title_entry widget"
        assert hasattr(app, "artist_entry"), "Missing artist_entry widget"
        assert hasattr(app, "search_btn"), "Missing search_btn widget"
        assert hasattr(app, "results_scroll"), "Missing results_scroll widget"
        assert hasattr(app, "save_btn"), "Missing save_btn widget"
        print("✓ All expected GUI attributes present")

        # Verify providers are configured
        assert len(app.provider_vars) > 0, "No providers configured"
        print(
            f"✓ {len(app.provider_vars)} providers configured: {list(app.provider_vars.keys())}"
        )

        # Clean up
        app.destroy()
        print("✓ GUI instance destroyed successfully")

        return True
    except Exception as e:
        print(f"✗ GUI instantiation test failed: {e}")
        import traceback

        traceback.print_exc()
        return False


def test_ui_variables():
    """Test that UI variables are properly initialized."""
    print("\nTesting UI variables...")
    try:
        from lyrics_fetcher_gui import LyricsFetcherGUI

        app = LyricsFetcherGUI()

        # Test string variables
        assert app.title_var.get() == "", "title_var should be empty initially"
        assert app.artist_var.get() == "", "artist_var should be empty initially"

        # Test selection variables
        assert app.name_format_var.get() == "file", (
            "name_format_var should default to 'file'"
        )
        assert app.lyric_mode_var.get() == "auto", (
            "lyric_mode_var should default to 'auto'"
        )

        # Test boolean variables
        assert app.include_metadata_var.get() == True, (
            "include_metadata_var should default to True"
        )
        assert app.strip_timestamps_var.get() == False, (
            "strip_timestamps_var should default to False"
        )
        assert app.overwrite_var.get() == False, "overwrite_var should default to False"

        print("✓ All UI variables initialized correctly")

        # Test setting variables
        app.title_var.set("Test Song")
        assert app.title_var.get() == "Test Song", "Failed to set title_var"
        print("✓ Variables can be set and retrieved")

        app.destroy()
        return True
    except Exception as e:
        print(f"✗ UI variables test failed: {e}")
        import traceback

        traceback.print_exc()
        return False


def test_provider_variables():
    """Test that all providers have associated variables."""
    print("\nTesting provider variables...")
    try:
        from lyrics_fetcher_gui import LyricsFetcherGUI

        app = LyricsFetcherGUI()

        expected_providers = ["lrclib", "lyricsovh", "kugou", "kuwo", "netease", "qq"]

        for provider in expected_providers:
            assert provider in app.provider_vars, f"Missing provider: {provider}"
            # All should be enabled by default
            assert app.provider_vars[provider].get() == True, (
                f"{provider} should be enabled by default"
            )

        print(
            f"✓ All {len(expected_providers)} providers have variables and are enabled"
        )

        # Test toggling a provider
        app.provider_vars["lrclib"].set(False)
        assert app.provider_vars["lrclib"].get() == False, "Failed to disable provider"
        print("✓ Provider variables can be toggled")

        app.destroy()
        return True
    except Exception as e:
        print(f"✗ Provider variables test failed: {e}")
        import traceback

        traceback.print_exc()
        return False


def main():
    """Run all tests."""
    print("=" * 60)
    print("Lyrics Fetcher GUI Test Suite")
    print("=" * 60)

    results = []

    # Run all tests
    results.append(("Imports", test_gui_imports()))
    results.append(("GUI Instantiation", test_gui_instantiation()))
    results.append(("UI Variables", test_ui_variables()))
    results.append(("Provider Variables", test_provider_variables()))

    # Summary
    print("\n" + "=" * 60)
    print("Test Summary")
    print("=" * 60)

    passed = sum(1 for _, result in results if result)
    total = len(results)

    for test_name, result in results:
        status = "✓ PASS" if result else "✗ FAIL"
        print(f"{status}: {test_name}")

    print(f"\nTotal: {passed}/{total} tests passed")

    return 0 if passed == total else 1


if __name__ == "__main__":
    sys.exit(main())
