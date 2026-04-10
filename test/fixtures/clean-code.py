#!/usr/bin/env python3
"""Clean code file — no secrets. Used to verify zero false positives."""

import os
import hashlib

# Reading credentials from environment (correct pattern)
API_KEY = os.environ.get("API_KEY")
SECRET = os.environ.get("MY_SECRET")
DATABASE_URL = os.environ.get("DATABASE_URL")

# Variable named 'password' but no literal value
def connect(host, port, password=None):
    """Connect to a service."""
    pass

# Hash values (long hex, but low entropy / known context)
CHECKSUM = "sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

# Example/placeholder values clearly labeled
EXAMPLE_KEY = "YOUR_API_KEY_HERE"  # Replace with your key
EXAMPLE_SECRET = "xxxxxxxxxxxxxxxx"

# Short identifier strings (not secrets)
USER_ID = "usr_12345"
TENANT = "acme-corp"

# Normal code with 'token' in variable name but referencing env
def get_auth_headers():
    token = os.environ["AUTH_TOKEN"]
    return {"Authorization": f"Bearer {token}"}

# URL without credentials
API_BASE = "https://api.example.com/v2"
WEBHOOK_URL = "https://example.com/webhook"
