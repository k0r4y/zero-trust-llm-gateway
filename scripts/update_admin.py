#!/usr/bin/env python3
import os
import sqlite3
from passlib.context import CryptContext

# Open WebUI uses bcrypt
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

DB_PATH = "/app/backend/data/webui.db"
EMAIL = os.environ.get("WEBUI_INIT_ADMIN_EMAIL")
PASSWORD = os.environ.get("WEBUI_INIT_ADMIN_PASSWORD")

if not EMAIL or not PASSWORD:
    print("Admin email or password not set, skipping.")
    exit(0)

conn = sqlite3.connect(DB_PATH)
cur = conn.cursor()

# Check if admin exists
cur.execute("SELECT id, password FROM auth WHERE email = ?", (EMAIL,))
row = cur.fetchone()

if row:
    user_id, current_hash = row
    # Update only if password has changed
    if not pwd_context.verify(PASSWORD, current_hash):
        new_hash = pwd_context.hash(PASSWORD)
        cur.execute("UPDATE auth SET password = ? WHERE id = ?", (new_hash, user_id))
        conn.commit()
        print(f"Updated password for {EMAIL}")
    else:
        print(f"Password for {EMAIL} is up to date.")
else:
    # Admin does not exist – create it
    new_hash = pwd_context.hash(PASSWORD)
    cur.execute(
        "INSERT INTO auth (email, password, role) VALUES (?, ?, ?)",
        (EMAIL, new_hash, "admin")
    )
    conn.commit()
    print(f"Created admin {EMAIL}")

conn.close()
