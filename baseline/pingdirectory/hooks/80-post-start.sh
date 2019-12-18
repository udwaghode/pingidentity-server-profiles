#!/usr/bin/env sh
#
# Ping Identity DevOps - Docker Build Hooks
#
#- This hook runs after the PingDirectory service has been started and is running.  It
#- will determine if it is part of a directory replication topology by the presence
#- of a TOPOLOGY_SERVICE_BAME .  If not present, then replication will not be enabled.  
#- Otherwise,
#- it will perform the following steps regarding replication.
#-
${VERBOSE} && set -x

# shellcheck source=../../pingcommon/hooks/pingcommon.lib.sh
. "${HOOKS_DIR}/pingcommon.lib.sh"

# shellcheck source=/dev/null
test -f "${STAGING_DIR}/env_vars" && . "${STAGING_DIR}/env_vars"
# shellcheck source=pingdirectory.lib.sh
test -f "${HOOKS_DIR}/pingdirectory.lib.sh" && . "${HOOKS_DIR}/pingdirectory.lib.sh"

echo "Running ldapsearch test on this Server (${_podInstanceName})"
echo "        ${_podHostname}:${_podLdapsPort}"
waitUntilLdapUp "${_podHostname}" "${_podLdapsPort}" ""

echo "
Updating the Server Instance hostname/ldaps-port:
         instance: ${_podInstanceName}
         hostname: ${_podHostname}
       ldaps-port: ${_podLdapsPort}"

dsconfig set-server-instance-prop --no-prompt --quiet \
    --instance-name "${_podInstanceName}" \
    --set hostname:${_podHostname} \
    --set ldaps-port:${_podLdapsPort}

_updateServerInstanceResult=$?
echo "Updating the Server Instance ${_podInstanceName} result=${_updateServerInstanceResult}"

#
# If we are in GENESIS State, then, no replication will be setup
#
if test "${PD_STATE}" == "GENESIS" ; then
    echo "PD_STATE is GENESIS ==> Replication on this server won't be setup until more instances are added"
    exit 0
fi

if test "${_podInstanceName}" == "${_seedInstanceName}"; then
    echo ""
    echo "We are the SEED Server: ${_seedInstanceName} --> No need to enable replication"
    echo "TODO: We need to check for other servers"
    exit 0
fi

echo "Running dsreplication enable"

echo "Running ldapsearch test on SEED Server (${_seedInstanceName})"
echo "        ${_seedHostname}:${_seedLdapsPort}"
waitUntilLdapUp "${_seedHostname}" "${_seedLdapsPort}" ""

#
# Check the topology prior to enabling replication to see if the Toplogy Master is different
# than the Seed server
#
_priorTopoFile="/tmp/priorTopology.json"
rm -rf "${_priorTopoFile}"
manage-topology export \
    --hostname "${_seedHostname}" \
    --port "${_seedLdapsPort}" \
    --exportFilePath "${_priorTopoFile}"
_priorNumInstances=$(cat ${_priorTopoFile} | jq ".serverInstances | length")

_masterTopologyInstance=$(ldapsearch --hostname "${_seedHostname}" --port "${_seedLdapsPort}" --terse --outputFormat json -b "cn=Mirrored subtree manager for base DN cn_Topology_cn_config,cn=monitor" -s base objectclass=* master-instance-name | jq -r .attributes[].values[])
_masterTopologyHostname="${_seedHostname}"
_masterTopologyLdapsPort="${_seedLdapsPort}"
_masterTopologyReplicationPort="${_seedReplicationPort}"


if test "${_priorNumInstances}" -eq 1; then
    echo "Only 1 instance (${_masterTopologyInstance}) found in current topology.  Adding 1st replica"
else
    if test "${_masterTopologyInstance}" = "${_seedInstanceName}"; then
        echo "Seed Instance is the Topology Master Instance"
        _masterTopologyHostname="${_seedHostname}"
        _masterTopologyLdapsPort="${_seedLdapsPort}"
        _masterTopologyReplicationPort="${_seedReplicationPort}"
    else
        echo "Topology master instance (${_masterTopologyInstance}) isn't seed instance (${_seedInstanceName})"
        
        _masterTopologyHostname=$(cat ${_priorTopoFile} | jq ".serverInstances[] | select(.instanceName==\"${_masterTopologyInstance}\") | .hostname")
        _masterTopologyLdapsPort=$(cat ${_priorTopoFile} | jq ".serverInstances[] | select(.instanceName==\"${_masterTopologyInstance}\") | .ldapsPort")
        _masterTopologyReplicationPort=$(cat ${_priorTopoFile} | jq ".serverInstances[] | select(.instanceName==\"${_masterTopologyInstance}\") | .replicationPort")
    fi
fi


printf "
#############################################
# Enabling Replication
#
# Current Master Topology Instance: ${_masterTopologyInstance}
#
#   %60s        %-60s
#   %60s  <-->  %-60s
#############################################
" "Topology Master Server" "POD Server" "${_masterTopologyHostname}:${_masterTopologyReplicationPort}" "${_podHostname}:${_podReplicationPort}"

dsreplication enable \
      --retryTimeoutSeconds ${RETRY_TIMEOUT_SECONDS} \
      --trustAll \
      --host1 "${_masterTopologyHostname}" \
      --port1 ${_masterTopologyLdapsPort} --useSSL1 \
      --replicationPort1 "${_masterTopologyReplicationPort}" \
      --bindDN1 "${ROOT_USER_DN}" --bindPasswordFile1 "${ROOT_USER_PASSWORD_FILE}" \
      \
      --host2 "${_podHostname}" \
      --port2 ${_podLdapsPort} --useSSL2 \
      --replicationPort2 "${_podReplicationPort}" \
      --bindDN2 "${ROOT_USER_DN}" --bindPasswordFile2 "${ROOT_USER_PASSWORD_FILE}" \
      \
      --adminUID "${ADMIN_USER_NAME}" --adminPasswordFile "${ADMIN_USER_PASSWORD_FILE}" \
      --no-prompt --ignoreWarnings \
      --baseDN "${USER_BASE_DN}" \
      --noSchemaReplication \
      --enableDebug --globalDebugLevel verbose

_replEnableResult=$?
echo "Replication enable for POD Server result=${_replEnableResult}"

if test ${_replEnableResult} -ne 0; then
    echo "Not running dsreplication initialize since enable failed with a non-successful return code"
    exit ${_replEnableResult}
fi

echo "Getting Topology from SEED Server"
rm -rf "${TOPOLOGY_FILE}"
manage-topology export \
    --hostname "${_seedHostname}" \
    --port "${_seedLdapsPort}" \
    --exportFilePath "${TOPOLOGY_FILE}"

cat "${TOPOLOGY_FILE}"

echo "Initializing replication on POD Server"
dsreplication initialize \
      --retryTimeoutSeconds ${RETRY_TIMEOUT_SECONDS} \
      --trustAll \
      \
      --topologyFilePath "${TOPOLOGY_FILE}" \
      \
      --hostDestination "${_podHostname}" --portDestination ${_podLdapsPort} --useSSLDestination \
      \
      --baseDN "${USER_BASE_DN}" \
      --adminUID "${ADMIN_USER_NAME}" \
      --adminPasswordFile "${ADMIN_USER_PASSWORD_FILE}" \
      --no-prompt \
      --enableDebug \
      --globalDebugLevel verbose

_replInitResult=$?
echo "Replication initialize result=${_replInitResult}"

# test ${_replInitResult} -eq 0 && touch "${REPL_SETUP_MARKER_FILE}"
exit ${_replInitResult}

