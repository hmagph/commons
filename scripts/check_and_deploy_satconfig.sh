#!/bin/bash

# Input env variables (can be received via a pipeline environment properties.file.
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "IMAGE_TAG=${IMAGE_TAG}"
echo "REGISTRY_URL=${REGISTRY_URL}"
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}"
echo "DEPLOYMENT_FILE=${DEPLOYMENT_FILE}"
echo "USE_ISTIO_GATEWAY=${USE_ISTIO_GATEWAY}"
echo "KUBERNETES_SERVICE_ACCOUNT_NAME=${KUBERNETES_SERVICE_ACCOUNT_NAME}"

echo "Use for custom Kubernetes cluster target:"
echo "KUBERNETES_MASTER_ADDRESS=${KUBERNETES_MASTER_ADDRESS}"
echo "KUBERNETES_MASTER_PORT=${KUBERNETES_MASTER_PORT}"
echo "KUBERNETES_SERVICE_ACCOUNT_TOKEN=${KUBERNETES_SERVICE_ACCOUNT_TOKEN}"

# View build properties
if [ -f build.properties ]; then 
  echo "build.properties:"
  cat build.properties | grep -v -i password
else 
  echo "build.properties : not found"
fi 
# also run 'env' command to find all available env variables
# or learn more about the available environment variables at:
# https://cloud.ibm.com/docs/services/ContinuousDelivery/pipeline_deploy_var.html#deliverypipeline_environment

# Input env variables from pipeline job
echo "PIPELINE_KUBERNETES_CLUSTER_NAME=${PIPELINE_KUBERNETES_CLUSTER_NAME}"
echo "CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE}"

echo "=========================================================="
echo "CHECKING DEPLOYMENT.YML manifest"
if [ -z "${DEPLOYMENT_FILE}" ]; then DEPLOYMENT_FILE=deployment.yml ; fi

echo "=========================================================="
echo "UPDATING manifest with image information"
IMAGE_REPOSITORY=${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}
echo -e "Updating ${DEPLOYMENT_FILE} with image name: ${IMAGE_REPOSITORY}:${IMAGE_TAG}"
NEW_DEPLOYMENT_FILE="$(dirname $DEPLOYMENT_FILE)/tmp.$(basename $DEPLOYMENT_FILE)"
# find the yaml document index for the K8S deployment definition
DEPLOYMENT_DOC_INDEX=$(yq read --doc "*" --tojson $DEPLOYMENT_FILE | jq -r 'to_entries | .[] | select(.value.kind | ascii_downcase=="deployment") | .key')
if [ -z "$DEPLOYMENT_DOC_INDEX" ]; then
  echo "No Kubernetes Deployment definition found in $DEPLOYMENT_FILE. Updating YAML document with index 0"
  DEPLOYMENT_DOC_INDEX=0
fi
# Update deployment with image name
cp ${DEPLOYMENT_FILE} ${NEW_DEPLOYMENT_FILE}
DEPLOYMENT_FILE=${NEW_DEPLOYMENT_FILE} # use modified file
yq write --inplace $DEPLOYMENT_FILE --doc $DEPLOYMENT_DOC_INDEX "spec.template.spec.containers[0].image" "${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}@${IMAGE_MANIFEST_SHA}"
# Set namespace in resource
yq write --inplace $DEPLOYMENT_FILE --doc "*" "metadata.namespace" "${CLUSTER_NAMESPACE}"
# Traceability for sat config
yq write --inplace $DEPLOYMENT_FILE --doc "*" "metadata.labels.razee/watch-resource" "lite" 
cat ${DEPLOYMENT_FILE}

echo "=========================================================="
echo "DEPLOYING using SATELLITE CONFIG"
set -x
CLUSTER_GROUP=phsatcon

CONFIG_NAME="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}"
SUBSCRIPTION_NAME="$CONFIG_NAME:$CLUSTER_GROUP"
VERSION_NAME="#$SOURCE_BUILD_NUMBER:"$(date -u "+%Y%m%d%H%M%S")

if ic ! sat config get --config "$CONFIG_NAME" $>/dev/null ; then
  ibmcloud sat config create --name "$CONFIG_NAME"
fi

# Create new resource version
ibmcloud sat config version create --name "$VERSION_NAME" --config "$CONFIG_NAME" --file-format yaml --read-config ${DEPLOYMENT_FILE}

# Create or update subscription
EXISTING_SUB=$(ibmcloud sat subscription ls | awk '{ print $1 }' | grep "$SUBSCRIPTION_NAME")
if [ -z "${EXISTING_SUB}" ]; then
# if ic ! sat subscription get --subscription "$SUBSCRIPTION_NAME" $>/dev/null ; then
  ibmcloud sat subscription create --name "$SUBSCRIPTION_NAME" --group "$CLUSTER_GROUP" --version "$VERSION_NAME" --config "$CONFIG_NAME"
else
  ibmcloud sat subscription update --name "$SUBSCRIPTION_NAME" --group "$CLUSTER_GROUP" --version "$VERSION_NAME"
fi


# echo -e "CHECKING deployment rollout of ${DEPLOYMENT_NAME}"
# echo ""
set -x
# if kubectl rollout status deploy/${DEPLOYMENT_NAME} --watch=true --timeout=${ROLLOUT_TIMEOUT:-"150s"} --namespace ${CLUSTER_NAMESPACE}; then
  STATUS="pass"
# else
#   STATUS="fail"
# fi
# set +x

# Dump events that occured during the rollout
# echo "SHOWING last events"
# kubectl get events --sort-by=.metadata.creationTimestamp -n ${CLUSTER_NAMESPACE}

# Record deploy information
if jq -e '.services[] | select(.service_id=="draservicebroker")' _toolchain.json > /dev/null 2>&1; then
  if [ -z "${KUBERNETES_MASTER_ADDRESS}" ]; then
    DEPLOYMENT_ENVIRONMENT="${PIPELINE_KUBERNETES_CLUSTER_NAME}:${CLUSTER_NAMESPACE}"
  else 
    DEPLOYMENT_ENVIRONMENT="${KUBERNETES_MASTER_ADDRESS}:${CLUSTER_NAMESPACE}"
  fi
  ibmcloud doi publishdeployrecord --env $DEPLOYMENT_ENVIRONMENT \
    --buildnumber ${SOURCE_BUILD_NUMBER} --logicalappname="${APP_NAME:-$IMAGE_NAME}" --status ${STATUS}
fi
if [ "$STATUS" == "fail" ]; then
  echo "DEPLOYMENT FAILED"
  echo "Showing registry pull quota"
  ibmcloud cr quota || true
  exit 1
fi

