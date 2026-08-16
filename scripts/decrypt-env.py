#!/usr/bin/env python3
"""
Robust SOPS secrets.enc.yaml -> compose/.env converter.
Does NOT use sed/awk; parses YAML keys safely.
"""
import sys
import re

def decrypt_to_env(input_path: str, output_path: str):
    # Run sops decrypt
    import subprocess
    result = subprocess.run(
        ["sops", "-d", input_path],
        capture_output=True,
        text=True,
        check=True
    )
    lines = result.stdout.splitlines()

    out_lines = []
    in_sops_block = False

    for raw_line in lines:
        line = raw_line.rstrip()
        if not line:
            continue
        # Skip sops metadata block (indented keys under 'sops:')
        if line.startswith("sops:"):
            in_sops_block = True
            continue
        if in_sops_block:
            if line.startswith(" ") or line.startswith("\t"):
                continue
            else:
                in_sops_block = False
        # Skip comments
        if line.lstrip().startswith("#"):
            continue
        # Parse top-level key: value
        match = re.match(r'^([A-Za-z0-9_]+):\s*(.*)$', line)
        if match:
            key = match.group(1)
            val = match.group(2).strip().strip('"').strip("'")
            out_lines.append(f"{key}={val}")

    with open(output_path, "w") as f:
        f.write("# Auto-generated from secrets.enc.yaml — do not edit manually\n")
        f.write("\n".join(out_lines) + "\n")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <secrets.enc.yaml> <output.env>")
        sys.exit(1)
    decrypt_to_env(sys.argv[1], sys.argv[2])
