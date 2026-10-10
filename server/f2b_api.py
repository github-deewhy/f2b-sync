#!/usr/bin/env python3
"""
AI-Watchdog Forensic API (Standalone)
Version: 1.0.0

Reads fail2ban-client status directly, ai-watchdog.log, 
and active Nginx logs to provide deep forensic context for banned IPs.
Automatically elevates to sudo if not already root.
"""
import os
import sys
import re
import json
import subprocess
import logging
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse
from collections import defaultdict

# ---------------- SemVer ----------------
__version__ = "1.0.0"

# ---------------- Auto-Elevate to Sudo ----------------
def ensure_root():
    if os.geteuid() != 0:
        logger.info("Elevating privileges to root via sudo...")
        os.execvp("sudo", ["sudo", sys.executable] + sys.argv)

# ---------------- Configuration ----------------
WATCHDOG_LOG_PATH = "/var/log/ai-watchdog.log"
NGINX_ACCESS_LOG = "/var/log/nginx/access.log"
NGINX_ERROR_LOG = "/var/log/nginx/error.log"
JAIL_NAME = "ai-watchdog"
HOST = "0.0.0.0"
PORT = 3000

# ---------------- Logging Setup ----------------
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S"
)
logger = logging.getLogger("ai-watchdog-api")

# ---------------- Attack Categorization ----------------
ATTACK_CATEGORIES = {
    "WordPress / CMS Probing": [r'wp-content', r'wp-includes', r'wp-config', r'wp-login', r'xmlrpc\.php', r'admin\.php', r'shell\.php', r'eval-stdin\.php', r'phpunit', r'phpinfo'],
    "Sensitive Config / Dotfile Exposure": [r'actuator', r'terraform\.tfstate', r'\.env', r'\.git', r'\.aws', r'\.ssh', r'\.dockerenv', r'appsettings\.json', r'cgi-bin/'],
    "Path Traversal (LFI)": [r'\.\./', r'%2e%2e', r'%32%65', r'etc/passwd', r'win\.ini', r'php://input', r'allow_url_include', r'auto_prepend_file'],
    "Remote Code Execution (RCE)": [r'\$\{jndi:', r'cmd\.exe', r'/bin/sh', r'/bin/bash', r'exec\(', r'system\(', r'passthru\(', r'eval\('],
    "SQL Injection (SQLi)": [r'union\s+select', r'information_schema', r'sleep\(\d+\)', r'waitfor\s+delay', r'select\s+.*\s+from', r'drop\s+table', r'insert\s+into'],
    "SSRF / Cloud Metadata": [r'169\.254\.169\.254', r'metadata\.google\.internal'],
    "Known Scanner / Bot": [r'l9explore', r'libredtail', r'masscan', r'nikto', r'sqlmap', r'nmap']
}

# ---------------- Data Extraction Functions ----------------

def get_geo_cc(ip):
    try:
        proc = subprocess.run(["geoiplookup", ip], capture_output=True, text=True, timeout=3)
        if proc.returncode == 0 and "GeoIP Country Edition:" in proc.stdout:
            res = proc.stdout.split("GeoIP Country Edition:")[1].split(",")[0].strip()
            if res and res != "IP Address not found":
                return res
    except Exception:
        pass
    return "--"

def get_banned_ips_directly():
    try:
        proc = subprocess.run(["fail2ban-client", "status", JAIL_NAME], capture_output=True, text=True, timeout=5)
        if proc.returncode == 0 and proc.stdout:
            ips = []
            in_ip_list = False
            for line in proc.stdout.splitlines():
                if "Banned IP list:" in line:
                    in_ip_list = True
                    parts = line.split("Banned IP list:")
                    if len(parts) > 1 and parts[1].strip():
                        ips.extend(parts[1].strip().split())
                    continue
                if in_ip_list:
                    if line.startswith("\t") or line.startswith("    "):
                        ips.extend(line.strip().split())
                    else:
                        break
            
            enriched = []
            for ip in ips:
                cc = get_geo_cc(ip)
                enriched.append({"ip": ip, "country": cc})
            
            logger.info(f"Found {len(enriched)} banned IPs in '{JAIL_NAME}' via fail2ban-client.")
            return enriched
    except Exception as e:
        logger.error(f"Failed to query fail2ban-client: {e}")
    return []

def get_ai_context_from_log(ip):
    context = {"ai_decision": "UNKNOWN", "total_requests": 0, "error_count": 0, "error_rate": "0%", "flagged_via": "unknown"}
    if not os.path.exists(WATCHDOG_LOG_PATH):
        return context

    pattern = re.compile(rf"AI evaluated {re.escape(ip)} \(Errors=(\d+)/(\d+), rate=([\d.]+)%, suspicious=(True|False)\): decision=(\w+)")
    try:
        cmd = ['grep', f"AI evaluated {ip}", WATCHDOG_LOG_PATH]
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
        if proc.returncode == 0 and proc.stdout:
            last_match_line = proc.stdout.strip().splitlines()[-1]
            match = pattern.search(last_match_line)
            if match:
                context["ai_decision"] = match.group(5)
                context["total_requests"] = int(match.group(2))
                context["error_count"] = int(match.group(1))
                context["error_rate"] = f"{match.group(3)}%"
                context["flagged_via"] = "suspicious_patterns" if match.group(4) == "True" else "error_rate"
    except Exception as e:
        logger.error(f"Error parsing ai-watchdog.log for {ip}: {e}")
    return context

def get_nginx_payloads(ip):
    logs = []
    # Reverted to awk on active logs, as agreed. Exact match on first column, limits to 50 lines.
    awk_script = f'$1 == "{ip}" {{print; if(++c>=50) exit}}'
    for logfile in [NGINX_ACCESS_LOG, NGINX_ERROR_LOG]:
        if not os.path.exists(logfile):
            continue
        try:
            cmd = ['awk', awk_script, logfile]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            if proc.returncode == 0 and proc.stdout:
                logs.extend(proc.stdout.strip().splitlines())
        except Exception as e:
            logger.error(f"Error extracting Nginx logs for {ip}: {e}")
            
    return list(dict.fromkeys(logs))[:50]

def classify_attacks(log_lines):
    matched_categories = set()
    sample_payloads = []
    for line in log_lines:
        if len(sample_payloads) < 5 and line not in sample_payloads and len(line) < 1000:
            sample_payloads.append(line)
        for category, patterns in ATTACK_CATEGORIES.items():
            if category in matched_categories:
                continue
            for pattern in patterns:
                if re.search(pattern, line, re.IGNORECASE):
                    matched_categories.add(category)
                    break
    return {"attack_types": list(matched_categories), "sample_payloads": sample_payloads}

def build_enriched_bans():
    raw_bans = get_banned_ips_directly()
    enriched = []
    for ban in raw_bans:
        ip = ban.get("ip")
        country = ban.get("country", "--")
        ai_context = get_ai_context_from_log(ip)
        nginx_logs = get_nginx_payloads(ip)
        classification = classify_attacks(nginx_logs)
        
        enriched.append({
            "ip": ip,
            "country": country,
            "ai_decision": ai_context["ai_decision"],
            "flagged_via": ai_context["flagged_via"],
            "total_requests": ai_context["total_requests"],
            "error_count": ai_context["error_count"],
            "error_rate": ai_context["error_rate"],
            "attack_types": classification["attack_types"] if classification["attack_types"] else ["Unclassified / Generic Scanning"],
            "sample_payloads": classification["sample_payloads"],
            "total_captured_events": len(nginx_logs)
        })
    return enriched

# ---------------- HTTP Handler ----------------
class APIHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/api/v1/bans':
            self.send_json_response(build_enriched_bans())
        elif path.startswith('/api/v1/bans/'):
            ip = path.split('/')[-1]
            self.handle_specific_ban(ip)
        elif path == '/api/v1/stats':
            self.handle_stats()
        elif path == '/':
            self.send_json_response({"status": "online", "service": "ai-watchdog-forensic-api", "version": __version__})
        else:
            self.send_json_response({"error": "Not Found"}, 404)

    def handle_specific_ban(self, ip):
        if not re.match(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$', ip):
            self.send_json_response({"error": "Invalid IP format"}, 400)
            return
        bans = build_enriched_bans()
        target = next((b for b in bans if b["ip"] == ip), None)
        if not target:
            self.send_json_response({"error": f"IP {ip} is not currently banned in {JAIL_NAME}"}, 404)
            return
        self.send_json_response(target)

    def handle_stats(self):
        bans = build_enriched_bans()
        stats = {
            "version": __version__,
            "total_active_bans": len(bans), 
            "attacks_by_type": defaultdict(int), 
            "attacks_by_country": defaultdict(int), 
            "ai_decisions": defaultdict(int), 
            "top_adversaries": []
        }
        for record in bans:
            stats["attacks_by_country"][record["country"]] += 1
            stats["ai_decisions"][record["ai_decision"]] += 1
            for atype in record["attack_types"]:
                stats["attacks_by_type"][atype] += 1
            stats["top_adversaries"].append({
                "ip": record["ip"], 
                "country": record["country"], 
                "events": record["total_captured_events"], 
                "error_rate": record["error_rate"]
            })
        
        stats["top_adversaries"] = sorted(stats["top_adversaries"], key=lambda x: x["events"], reverse=True)[:10]
        stats["attacks_by_type"] = dict(stats["attacks_by_type"])
        stats["attacks_by_country"] = dict(stats["attacks_by_country"])
        stats["ai_decisions"] = dict(stats["ai_decisions"])
        self.send_json_response(stats)

    def send_json_response(self, data, status=200):
        self.send_response(status)
        self.send_header('Content-type', 'application/json')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode('utf-8'))

    def log_message(self, format, *args):
        logger.info(f"{self.client_address[0]} - - [{self.log_date_time_string()}] {format % args}")

# ---------------- Main Execution ----------------
if __name__ == '__main__':
    ensure_root()
    
    server_address = (HOST, PORT)
    httpd = HTTPServer(server_address, APIHandler)
    logger.info(f"Starting AI-Watchdog Forensic API v{__version__} on {HOST}:{PORT}")
    logger.info("Endpoints: /api/v1/bans | /api/v1/bans/{ip} | /api/v1/stats")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down API server")
        httpd.server_close()
