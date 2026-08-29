"""Shared test setup. Must run BEFORE any app import so the app is wired
for offline testing: the crypto market falls back to the deterministic
simulator instead of hitting Coinbase (no network in unit tests)."""

import os

os.environ.setdefault("TRADER_CRYPTO_SOURCE", "sim")
