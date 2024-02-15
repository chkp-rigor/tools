#!/bin/bash
#DEFAULTS
NS="checkpoint" #default NS for Checkpoint cloudguard containers products
RELEASE_NAME="asset-mgmt"
DEBUG=0
WORKING_DIR=$(pwd)
TEMP_DIR="/tmp/cloudguard-container-collect-tmp"
DATE="$(date '+%Y-%m-%d_%H-%M-%S_%Z')"
LOG_FILE="${WORKING_DIR}/cloudguard-container-info-collect-${DATE}.log"
COLLECT_CRD=1
PROXY_NAME=""
PROXY=0
OUTPUT_TARBALL_NAME="cloudguard-container-info-${DATE}.tar.gz"
PATH_TO_S3=""
VERSION="0.0.2"
SCRIPT_NAME=""
COLLECT_METRICS=0

##
RM="/bin/rm"
MKDIR="/bin/mkdir"
TAR="/bin/tar"

#End of Defaults

usage()
{
	echo
	echo "Bash script to collect configuration and logs of CheckPoint cloudguard Containers helm release."
	echo "Pre-requisites:"
	echo "	1. User should have kubectl and helm installed on the machine where this script is running "
	echo "	   and kubeconfig context set to the relevant cluster."
	echo "	2. User should have proper permissions to execute helm and kubectl commands for relevant cluster."
	echo "	3. Following common linux commands should be available: rm, tar, mkdir." 
	echo
	echo "Version: ${VERSION}"
	echo
	echo "Syntax: $0 [-r|n|c|o|d|m|h]"
	echo
	echo "options:"
	echo "-r/--release <Helm release name>"
	echo "-n/--namespace <Namespace>" 
	echo "-c/--crd"
	echo "	Specifies if collect cloudguard CRD's. Default: enabled."
	echo "-o <file_name> Specifies custom name for output tarball file"
	echo "-d/--debug Enables debug"
	echo "-m/--metrics Default: disabled"
	echo "	Specifies if collect Cloudguard agents containers metrics. If metrics collection is enabled, 'kubectl exec' will run on fluentbit containers."
	echo "-h/--help Display a brief usage message and then exit."
	echo
	exit -1
}
testEnv()
{
	#test kubectl
	error=$(kubectl version)
	result=$?
	Log "Starting!"
	Log "Script execution could take few minutes."

	if [[ ${result} == 0 ]]
	then
		printDebug "kubectl working"
	else
		Log "kubectl command error: ${error}"
		exitOnError "Check that kubectl installed and user have appropriate permissions"
	fi
	
	#test helm if kubectl ok
	error=$(helm status ${RELEASE_NAME} -n ${NS} )
	result=$?
	if [[ ${result} == 0 ]]
	then
		printDebug "helm working. Release ${RELEASE_NAME} found"
	else
		Log "helm command error: ${error}"
		# do not exitOnError in case of helm errors
		Log "Check that helm installed, user has appropriate permissions and release ${RELEASE_NAME} exists in namespace ${NS}"
	fi
}
exitOnError()
{
	Log "Script stopped with error: $@"
	cleanup
	echo "Additional details please see in the log file: ${LOG_FILE} "
	exit -1
}
parseArgs()
{
	printDebug "Start parsing args"
	SCRIPT_NAME=$0
	while [[ $# -gt 0 ]]
	do
	key="$1"
	case ${key} in
		-n|--namespace)
			NS=$2
			shift
			shift
			;;
		-r|--release)
			RELEASE_NAME=$2
			shift
			shift
			;;
		-d|--debug)
			DEBUG=1
			shift
			;;
		-o)
			OUTPUT_TARBALL_NAME=$2
			shift
			shift
			;;
		-c|--crd)
			if [[ "$2" == "no" ]]
			then
			  COLLECT_CRD=0
			fi
			shift
			shift
			;;
		-h|--help)
			usage
			;;
		-m|--metrics)
			COLLECT_METRICS=1
			shift
			;;
		*)
			echo "Wrong param: $1"
			echo "run ${SCRIPT_NAME} -h/--help to see usage"
			exit -1
			;;
	esac
	done
}
printDebug()
{
	if [[ $DEBUG == 1 ]] 
	then
		Log "<Debug> $@"
	fi
}
Log()
{
	timestamp="$(date "+%F-%T-%Z")"
	if [ -n "$1" ]
	then
		IN="$@"
	else
		read -t 0.1 IN # This reads a string from stdin and stores it in a variable called IN
		if [[ $IN == "" ]]
		then
			return
		fi
	fi
	echo "${timestamp}: ${IN}" >> ${LOG_FILE}
	echo ${IN}
}
collectContainersLogs()
{
	printDebug "Collecting Logs"
	logs_folder=${TEMP_DIR}/logs
	${MKDIR} ${logs_folder} 2>&1 | Log
	pods_list=$(kubectl get pod -n ${NS} -l="app.kubernetes.io/instance=${RELEASE_NAME}" --no-headers -o jsonpath='{.items[*].metadata.name}')
	Log "Collecting logs of cloudguard Pods in ${NS} namespace"

	for pod in ${pods_list} ; do
		containers=`kubectl -n ${NS} get pod ${pod} -o jsonpath='{.spec.containers[*].name}'` 
		containers="${containers} $(kubectl -n ${NS} get pod ${pod} -o jsonpath='{.spec.initContainers[*].name}')"
		printDebug "pod ${pod} containers: $containers"
		for container in ${containers} ; do
			`kubectl -n ${NS} logs $pod -c ${container} | gzip > ${logs_folder}/${pod}_${container}.log.gz`
			`kubectl -n ${NS} logs $pod -c ${container} -p 2>/dev/null > ${logs_folder}/previous.log &&  gzip -c ${logs_folder}/previous.log > ${logs_folder}/${pod}_${container}-previous.log.gz  2>/dev/null && ${RM} -f ${TEMP_DIR}/previous.log`
		done
		#clean temp file
		${RM} -f ${logs_folder}/previous.log
	done
	printDebug "End of logs collection"
}
collectConfigMaps()
{
	printDebug "collecting ConfigMaps"
	configMaps_folder=${TEMP_DIR}/configMaps
	${MKDIR} ${configMaps_folder} 2>&1 | Log
	cm_list=$(kubectl get cm -n ${NS} -l="app.kubernetes.io/instance=${RELEASE_NAME}" --no-headers -o jsonpath='{.items[*].metadata.name}')
	Log "Collecting following ConfigMaps in ${NS} namespace: ${cm_list}"
	for cm in ${cm_list} ; do
		configMap=$(kubectl -n ${NS} get cm ${cm} -o yaml )
		printDebug "collecting configMap ${cm}"
		`echo ${configMap} | gzip > ${configMaps_folder}/cm-${cm}.yaml.gz`
		`kubectl -n ${NS} get cm ${cm} -o custom-columns=data:.data | gzip  > ${configMaps_folder}/cm-${cm}-data-only.yaml.gz`
	done
	printDebug "End of configMaps collection"
}

collectPodsGeneralInfo()
{
	printDebug "collecting Pods General Info"
	general_info_folder=${TEMP_DIR}/pods_general_info
	${MKDIR} ${general_info_folder} 2>&1 | Log
	pods_list=$(kubectl get pod -n ${NS} -l="app.kubernetes.io/instance=${RELEASE_NAME}" --no-headers -o jsonpath='{.items[*].metadata.name}')
	kubectl get pod -o wide -n ${NS} -l="app.kubernetes.io/instance=${RELEASE_NAME}" | gzip > ${general_info_folder}/pods_get.txt.gz
	for pod in ${pods_list} ; do
		printDebug "collecting pod describe for ${pod}"
		`kubectl -n ${NS} describe pod ${pod} | gzip  > ${general_info_folder}/${pod}-describe.txt.gz`
	done
	printDebug "End of pods Info collection"
}

collectHelmRelease()
{
	printDebug "collecting Helm Release data"

	Log "Collecting helm release data. Release name: ${RELEASE_NAME}"
	`helm history -n ${NS}  ${RELEASE_NAME} | gzip > ${TEMP_DIR}/helmHistory-${RELEASE_NAME}-${NS}.yaml.gz` 

	
}
collectResourcesYamls()
{
	resources_folder=${TEMP_DIR}/resources
	${MKDIR} ${resources_folder} 2>&1 | Log
	printDebug "collecting ${RELEASE_NAME} resources yamls"
	`kubectl get all -n ${NS} -l="app.kubernetes.io/instance=${RELEASE_NAME}" -o yaml | gzip  > ${resources_folder}/${RELEASE_NAME}-resources.yaml.gz `
}
collectNodesData()
{
	printDebug "collecting Nodes configuration"
	nodes_folder=${TEMP_DIR}/nodes
	${MKDIR} ${nodes_folder} 2>&1 | Log
	kubectl get node -o yaml | gzip  > ${nodes_folder}/allNodes.yaml.gz
	kubectl describe node | gzip  > ${nodes_folder}/nodes-describe.txt.gz
}
collectPspData()
{
	printDebug "collecting PSP configuration"
	kubectl get psp -o yaml | gzip  > ${TEMP_DIR}/psp.yaml.gz
}
collectCrdData()
{
	printDebug "collecting cloudguard CRDs"
	crds_folder=${TEMP_DIR}/crds
	${MKDIR} ${crds_folder} 2>&1 | Log
	if [[ ${COLLECT_CRD} == 1 ]]
	then
		crds_list=$(kubectl get crd -n ${NS} -l="app.kubernetes.io/instance=${RELEASE_NAME}" -o jsonpath='{.items[*].spec.names.kind}')
		Log "Collecting following CRD's from ${NS} namespace: ${crds_list}"
		for crd in ${crds_list} ; do
			printDebug "crd-name: ${crd}"
			kubectl -n ${NS} get ${crd} -o yaml | gzip  > ${crds_folder}/crd-${crd}.yaml.gz
		done
	else
		printDebug "collecting of CRDS disabled by user"
	fi
	printDebug "End of CRD's collection"
}
collectMetrics()
{
	printDebug "collecting fluentbit metrics"
	metrics_root_folder=${TEMP_DIR}/metrics
	metrics_folder=${metrics_root_folder}/metric
	metrics_tail_folder=${metrics_root_folder}/metric-tail
        Log "Collecting metrics from fluentbit"
	${MKDIR} ${metrics_root_folder} 2>&1 | Log
	${MKDIR} ${metrics_folder} 2>&1 | Log
	${MKDIR} ${metrics_tail_folder} 2>&1 | Log

	pods_list=$(kubectl get pod -n ${NS} -l="app.kubernetes.io/instance=${RELEASE_NAME}" --no-headers -o jsonpath='{.items[*].metadata.name}')

	for pod in ${pods_list} ; do
		res=`kubectl -n ${NS} exec ${pod} -c fluentbit -- tar -C / -czf - metric 2>&1 > ${metrics_folder}/${pod}.tgz`
		res=`kubectl -n ${NS} exec ${pod} -c fluentbit -- tar -C / -czf - metric-tail 2>&1 > ${metrics_tail_folder}/${pod}.tgz`
	done
}
cleanup()
{
	printDebug "start cleanup"
	error=$(${RM} -rf ${TEMP_DIR})
	result=$?
	logDetails="Log file: ${LOG_FILE}"
	
	if [[ ${result} == 0 ]]
	then
		echo ${logDetails}
		Log "Cleanup succeeded. Exiting ..."
	else
		exitOnError "cleanup failed with error: ${error}"
	fi
	
}
createTarball()
{
	printDebug "Going to create tarball: ${WORKING_DIR}/${OUTPUT_TARBALL_NAME}"
	error=$(${TAR} cvfz ${WORKING_DIR}/${OUTPUT_TARBALL_NAME} -C ${TEMP_DIR}/ . 2>&1)
	result=$? 
	if [[ ${result} == 0 ]]
	then
		Log "Created tarball ${WORKING_DIR}/${OUTPUT_TARBALL_NAME}"
	else
		Log "Failed to create tarball with collected info. Error ${error}"
	fi
}
main()
{
	args=$@
	parseArgs ${args}
	Log "Starting ${SCRIPT_NAME} script" 
	printDebug "Namespace = ${NS}"
	${RM} -rf ${TEMP_DIR} 2>&1 | Log
	${MKDIR} ${TEMP_DIR} 2>&1 | Log
	testEnv
	collectNodesData
	collectContainersLogs
	collectConfigMaps
	collectCrdData
	#collectHelmRelease
	collectResourcesYamls
	collectPodsGeneralInfo
	#collect kube-system pods list
	kubectl get pod -n kube-system -o wide > ${TEMP_DIR}/kube-system-details.txt

	if [[ ${COLLECT_METRICS} == 1 ]]
	then
		collectMetrics
	fi
	
	createTarball
	cleanup
}

#call main
main $@

exit 0
