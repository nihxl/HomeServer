  GNU nano 6.2                               /usr/local/bin/smart-check.sh                                         
#!/bin/bash
LOGFILE="/home/nihal/Server/Docker/smart-logs/sda_smart.log"
echo "===== $(date) =====" >> "$LOGFILE"
smartctl -a /dev/sda | grep -E "Reallocated_Sector_Ct|Current_Pending_Sector|Reallocated_Event_Count|Power_On_Hour>
echo "" >> "$LOGFILE"
