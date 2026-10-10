#!/usr/bin/env bash
set -o pipefail

[[ $EUID -ne 0 ]] && exec sudo -- "$0" "$@"

# Argument parsing for JSON mode
JSON_MODE=false
JSON_FILE="f2b_status.json" # Default output file
while [[ $# -gt 0 ]]; do
    case $1 in
        -j|--json)
            JSON_MODE=true
            # Allow optional custom filename if provided
            if [[ -n "$2" && "$2" != -* ]]; then
                JSON_FILE="$2"
                shift
            fi
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [[ -t 1 ]]; then
    R=$'\033[0;31m'; G=$'\033[0;32m'; Y=$'\033[0;33m'
    B=$'\033[0;34m'; M=$'\033[0;35m'; C=$'\033[0;36m'
    W=$'\033[1;37m'; D=$'\033[2m'; BD=$'\033[1m'; N=$'\033[0m'
else
    R=""; G=""; Y=""; B=""; M=""; C=""; W=""; D=""; BD=""; N=""
fi

command -v fail2ban-client >/dev/null || { echo "fail2ban-client missing" >&2; exit 1; }
fail2ban-client ping >/dev/null 2>&1 || { echo "fail2ban not running" >&2; exit 1; }

rep() { local c="$1" n="$2" s=""; for ((i=0;i<n;i++)); do s+="$c"; done; printf '%s' "$s"; }
HEAVY=$(rep '=' 96); THIN=$(rep '-' 96); DOTS=$(rep '.' 76)

mapfile -t JAILS < <(
    fail2ban-client status 2>/dev/null \
    | sed -n 's/.*Jail list:[[:space:]]*//p' \
    | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
)
(( ${#JAILS[@]} )) || { echo "No jails."; exit 0; }

declare -A CUR TOT FCUR FTOT FILES IPS
for j in "${JAILS[@]}"; do
    r=$(fail2ban-client status "$j" 2>/dev/null)
    CUR[$j]=$(sed -n 's/.*Currently banned:[[:space:]]*//p' <<<"$r"); CUR[$j]=${CUR[$j]:-0}
    TOT[$j]=$(sed -n 's/.*Total banned:[[:space:]]*//p'     <<<"$r"); TOT[$j]=${TOT[$j]:-0}
    FCUR[$j]=$(sed -n 's/.*Currently failed:[[:space:]]*//p' <<<"$r"); FCUR[$j]=${FCUR[$j]:-0}
    FTOT[$j]=$(sed -n 's/.*Total failed:[[:space:]]*//p'     <<<"$r"); FTOT[$j]=${FTOT[$j]:-0}
    FILES[$j]=$(sed -n 's/.*File list:[[:space:]]*//p'       <<<"$r")
    IPS[$j]=$(sed -n 's/.*Banned IP list:[[:space:]]*//p'    <<<"$r")
done

geo_cc() { 
    if command -v geoiplookup >/dev/null 2>&1; then
        local res
        res=$(geoiplookup "$1" 2>/dev/null | awk -F': ' '/GeoIP Country Edition/{print $2}' | cut -d, -f1 | xargs)
        if [[ -z "$res" || "$res" == "IP Address not found" ]]; then
            echo "--"
        else
            echo "$res"
        fi
    else
        echo "--"
    fi
}

# ==========================================
# JSON MODE OUTPUT (Defaults to f2b_status.json)
# ==========================================
if [[ "$JSON_MODE" == true ]]; then
    t_cb=0; t_tb=0; t_cf=0; t_tf=0
    for j in "${JAILS[@]}"; do
        t_cb=$((t_cb + ${CUR[$j]:-0}))
        t_tb=$((t_tb + ${TOT[$j]:-0}))
        t_cf=$((t_cf + ${FCUR[$j]:-0}))
        t_tf=$((t_tf + ${FTOT[$j]:-0}))
    done

    json="{"
    json+="\"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S %Z')\","
    json+="\"total_jails\": ${#JAILS[@]},"
    json+="\"totals\": {"
    json+="\"currently_banned\": $t_cb,"
    json+="\"total_banned\": $t_tb,"
    json+="\"currently_failed\": $t_cf,"
    json+="\"total_failed\": $t_tf"
    json+="},"
    json+="\"jails\": ["

    first_jail=true
    for j in "${JAILS[@]}"; do
        [[ "$first_jail" == false ]] && json+=","
        first_jail=false

        cb=${CUR[$j]:-0}; tb=${TOT[$j]:-0}; cf=${FCUR[$j]:-0}; tf=${FTOT[$j]:-0}
        status="idle"; [[ $cb -gt 0 ]] && status="active"

        fl=${FILES[$j]:-""}
        logs_json="["
        first_log=true
        if [[ -n "$fl" ]]; then
            for f in ${fl//,/ }; do
                f=$(xargs <<<"$f")
                [[ -z "$f" ]] && continue
                [[ "$first_log" == false ]] && logs_json+=","
                first_log=false
                f_escaped="${f//\\/\\\\}"
                f_escaped="${f_escaped//\"/\\\"}"
                logs_json+="\"$f_escaped\""
            done
        fi
        logs_json+="]"

        ip_list=${IPS[$j]:-""}
        ips_json="["
        first_ip=true
        if [[ -n "$ip_list" ]]; then
            for x in $ip_list; do
                [[ "$first_ip" == false ]] && ips_json+=","
                first_ip=false
                cc=$(geo_cc "$x")
                ips_json+="{\"ip\": \"$x\", \"country\": \"$cc\"}"
            done
        fi
        ips_json+="]"

        json+="{"
        json+="\"name\": \"$j\","
        json+="\"status\": \"$status\","
        json+="\"currently_banned\": $cb,"
        json+="\"total_banned\": $tb,"
        json+="\"currently_failed\": $cf,"
        json+="\"total_failed\": $tf,"
        json+="\"log_files\": $logs_json,"
        json+="\"banned_ips\": $ips_json"
        json+="}"
    done

    json+="]}"

    # Automatically write to file
    echo "$json" > "$JSON_FILE"
    echo "✅ JSON data successfully saved to: $JSON_FILE" >&2
    exit 0
fi

# ==========================================
# STANDARD CLI OUTPUT (100% Original Logic)
# ==========================================
echo
printf "${BD}${W}+%s+${N}\n" "$HEAVY"
printf "${BD}${W}| %-94s |${N}\n" "FAIL2BAN - FULL REPORT"
printf "${BD}${W}| %-94s |${N}\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')  |  ${#JAILS[@]} jails"
printf "${BD}${W}+%s+${N}\n" "$HEAVY"

printf "\n${BD}${C}>> OVERVIEW${N}\n${BD}${C}%s${N}\n" "$THIN"
printf "  ${BD}%-24s %8s %8s %9s %9s   %s${N}\n" JAIL BANNED TOTAL FAILED TOTFAIL STATUS
printf "  ${D}%s${N}\n" "$DOTS"
sc=0; st=0; sf=0; stf=0
for j in "${JAILS[@]}"; do
    cb=${CUR[$j]}; tb=${TOT[$j]}; cf=${FCUR[$j]}; tf=${FTOT[$j]}
    ((cb>0)) && cbc="$R" || cbc="$G"
    ((cf>0)) && cfc="$Y" || cfc="$G"
    ((cb>0)) && s="${R}* active${N}" || s="${G}+ idle${N}"
    printf "  ${BD}%-24s${N} ${cbc}%8s${N} %8s ${cfc}%9s${N} %9s   %b\n" "$j" "$cb" "$tb" "$cf" "$tf" "$s"
    sc=$((sc+cb)); st=$((st+tb)); sf=$((sf+cf)); stf=$((stf+tf))
done
printf "  ${D}%s${N}\n" "$(rep '-' 76)"
printf "  ${BD}%-24s${N} ${R}%8d${N} %8d ${Y}%9d${N} %9d\n" "TOTAL (${#JAILS[@]})" "$sc" "$st" "$sf" "$stf"

printf "\n${BD}${B}>> JAIL DETAIL${N}\n${BD}${B}%s${N}\n" "$THIN"
for j in "${JAILS[@]}"; do
    cb=${CUR[$j]}; tb=${TOT[$j]}; cf=${FCUR[$j]}; tf=${FTOT[$j]}
    fl=${FILES[$j]}; ip=${IPS[$j]}
    ((cb>0)) && cbc="$R" || cbc="$G"
    ((cf>0)) && cfc="$Y" || cfc="$G"

    printf "\n  ${BD}${W}+-- ${M}%s${N}\n" "$j"
    printf "  ${BD}${W}|${N} ${BD}Filter${N}\n"
    printf "  ${BD}${W}|${N}   %-18s ${cfc}%s${N}\n" "Currently failed:" "$cf"
    printf "  ${BD}${W}|${N}   %-18s %s\n"        "Total failed:"     "$tf"
    [[ -n "$fl" ]] && for f in ${fl//,/ }; do
        f=$(xargs <<<"$f"); [[ -z "$f" ]] && continue
        [[ -r "$f" ]] && printf "  ${BD}${W}|${N}   %-18s ${G}+${N} %s\n" "Log file:" "$f" \
                      || printf "  ${BD}${W}|${N}   %-18s ${R}!${N} %s\n" "Log file:" "$f"
    done
    printf "  ${BD}${W}|${N} ${BD}Actions${N}\n"
    printf "  ${BD}${W}|${N}   %-18s ${cbc}%s${N}\n" "Currently banned:" "$cb"
    printf "  ${BD}${W}|${N}   %-18s %s\n"        "Total banned:"     "$tb"
    if [[ -n "$ip" ]]; then
        n=0; for _ in $ip; do n=$((n+1)); done
        printf "  ${BD}${W}|${N}   %-18s ${R}%d${N}\n" "Banned IPs:" "$n"
        for x in $ip; do
            printf "  ${BD}${W}|${N}     ${R}*${N} %-18s ${D}%s${N}\n" "$x" "$(geo_cc "$x")"
        done
    else
        printf "  ${BD}${W}|${N}   %-18s ${G}none${N}\n" "Banned IPs:"
    fi
    printf "  ${BD}${W}+--${N}\n"
done

echo
printf "  ${D}Unban: sudo fail2ban-client set <jail> unbanip <ip>${N}\n"