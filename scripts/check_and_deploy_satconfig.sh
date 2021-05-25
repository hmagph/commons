#!/bin/bash
set -x
# Input env variables (can be received via a pipeline environment properties.file.
echo "IMAGE_NAME=${IMAGE_NAME}"
echo "IMAGE_TAG=${IMAGE_TAG}"
echo "REGISTRY_URL=${REGISTRY_URL}"
echo "REGISTRY_NAMESPACE=${REGISTRY_NAMESPACE}"
echo "DEPLOYMENT_FILE=${DEPLOYMENT_FILE}"
echo "KUBERNETES_SERVICE_ACCOUNT_NAME=${KUBERNETES_SERVICE_ACCOUNT_NAME}"

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
echo "CLUSTER_NAMESPACE=${CLUSTER_NAMESPACE}"
echo "SATELLITE_CLUSTER_GROUP=${SATELLITE_CLUSTER_GROUP}"
echo "SATELLITE_CONFIG=${SATELLITE_CONFIG}"
echo "SATELLITE_SUBSCRIPTION=${SATELLITE_SUBSCRIPTION}"
echo "SATELLITE_CONFIG_VERSION=${SATELLITE_CONFIG_VERSION}"

echo "=========================================================="
echo "CHECKING DEPLOYMENT.YML manifest"
if [ -z "${DEPLOYMENT_FILE}" ]; then DEPLOYMENT_FILE=deployment.yml ; fi

echo "=========================================================="
echo -e "CONFIGURING ACCESS to private image registry from namespace ${CLUSTER_NAMESPACE}"
KUBERNETES_SERVICE_ACCOUNT_NAME="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}"
IMAGE_PULL_SECRET_NAME="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}-${REGISTRY_URL}"
IMAGE_PULL_SECRET_SHA256=$(printf "${IMAGE_PULL_SECRET_NAME}${PIPELINE_BLUEMIX_API_KEY}" | sha256sum)
echo "Image pull secret SHA256: $IMAGE_PULL_SECRET_SHA256"

export SATELLITE_CONFIG_ACCOUNT="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}-service-account"
export SATELLITE_SUBSCRIPTION_ACCOUNT="$SATELLITE_CONFIG_ACCOUNT-$SATELLITE_CLUSTER_GROUP"
export SATELLITE_CONFIG_VERSION_ACCOUNT="$IMAGE_PULL_SECRET_SHA256"
if ! ic sat config version get --config "$SATELLITE_CONFIG_ACCOUNT" --version "$SATELLITE_CONFIG_VERSION_ACCOUNT" &>/dev/null; then
  echo -e "Current image pull secret$ ${IMAGE_PULL_SECRET_NAME} not found in ${CLUSTER_NAMESPACE}, creating it"
  if ! ibmcloud sat config get --config "$SATELLITE_CONFIG_ACCOUNT" &>/dev/null ; then
    ibmcloud sat config create --name "$SATELLITE_CONFIG_ACCOUNT"
  fi
  export REGISTRY_AUTH=$(echo "{\"auths\":{\"${REGISTRY_URL}\":{\"auth\":\"$(echo -n iamapikey:${PIPELINE_BLUEMIX_API_KEY} | base64)\"}}}" | base64)
  ACCOUNT_FILE="${SATELLITE_CONFIG_ACCOUNT}.yaml"
  cat > ${ACCOUNT_FILE} << EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: ${KUBERNETES_SERVICE_ACCOUNT_NAME}
  namespace: ${CLUSTER_NAMESPACE}
imagePullSecrets:
  - name: ${IMAGE_PULL_SECRET_NAME}
---
apiVersion: v1
kind: Secret
metadata:
  name: ${IMAGE_PULL_SECRET_NAME}
  namespace: ${CLUSTER_NAMESPACE}
data:
  .dockerconfigjson: ${REGISTRY_AUTH}
type: kubernetes.io/dockerconfigjson
EOF
  cat ${ACCOUNT_FILE}
  ibmcloud sat config version create --name "$SATELLITE_CONFIG_VERSION_ACCOUNT" --config "$SATELLITE_CONFIG_ACCOUNT" --file-format yaml --read-config ${ACCOUNT_FILE}
  # Create or update subscription
  EXISTING_SUB_ACCOUNT=$(ibmcloud sat subscription ls -q | grep "$SATELLITE_SUBSCRIPTION_ACCOUNT" || true)
  if [ -z "${EXISTING_SUB_ACCOUNT}" ]; then
  # if ! ibmcloud sat subscription get --subscription "$SATELLITE_SUBSCRIPTION_ACCOUNT" &>/dev/null ; then
    ibmcloud sat subscription create --name "$SATELLITE_SUBSCRIPTION_ACCOUNT" --group "$SATELLITE_CLUSTER_GROUP" --version "$SATELLITE_CONFIG_VERSION_ACCOUNT" --config "$SATELLITE_CONFIG_ACCOUNT"
  else
    ibmcloud sat subscription update --subscription "$SATELLITE_SUBSCRIPTION_ACCOUNT" -f --group "$SATELLITE_CLUSTER_GROUP" --version "$SATELLITE_CONFIG_VERSION_ACCOUNT"
  fi
else
  echo -e "Current Image pull secret ${IMAGE_PULL_SECRET_NAME} already found in ${CLUSTER_NAMESPACE}"
fi

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
cp ${DEPLOYMENT_FILE} ${NEW_DEPLOYMENT_FILE}
DEPLOYMENT_FILE=${NEW_DEPLOYMENT_FILE} # use modified file
yq write --inplace $DEPLOYMENT_FILE --doc $DEPLOYMENT_DOC_INDEX "spec.template.spec.containers[0].image" "${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}@${IMAGE_MANIFEST_SHA}"

# Set namespace in resources
echo -e "Updating ${DEPLOYMENT_FILE} with namespace: ${CLUSTER_NAMESPACE}"
yq write --inplace $DEPLOYMENT_FILE --doc "*" "metadata.namespace" "${CLUSTER_NAMESPACE}"

# Traceability for sat config in resources
echo -e "Updating ${DEPLOYMENT_FILE} with traceability label: metadata.labels.razee/watch-resource"
yq write --inplace $DEPLOYMENT_FILE --doc "*" "metadata.labels.razee/watch-resource" "lite" 

# Set serviceaccount in resources
echo -e "Updating ${DEPLOYMENT_FILE} with namespace: ${SERVICE_ACCOUNT}"
yq write --inplace $DEPLOYMENT_FILE --doc "*" "spec.template.spec.serviceAccountName" "${KUBERNETES_SERVICE_ACCOUNT_NAME}"

cat ${DEPLOYMENT_FILE}

echo "=========================================================="
echo "DEPLOYING using SATELLITE CONFIG"
set -x

ic plugin list
ic plugin update kubernetes-service -f

if [ -z "${SATELLITE_CONFIG}" ]; then
  export SATELLITE_CONFIG="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}-resources"
fi
if [ -z "${SATELLITE_SUBSCRIPTION}" ]; then
  export SATELLITE_SUBSCRIPTION="$SATELLITE_CONFIG-$SATELLITE_CLUSTER_GROUP"
fi
if [ -z "${SATELLITE_CONFIG_VERSION}" ]; then
  export SATELLITE_CONFIG_VERSION="$SOURCE_BUILD_NUMBER-"$(date -u "+%Y%m%d%H%M%S") # should only contain alphabets, numbers, underscore and hyphen
fi

if ! ibmcloud sat config get --config "$SATELLITE_CONFIG" &>/dev/null ; then
  ibmcloud sat config create --name "$SATELLITE_CONFIG"
fi

# Create new resource version
ibmcloud sat config version create --name "$SATELLITE_CONFIG_VERSION" --config "$SATELLITE_CONFIG" --file-format yaml --read-config ${DEPLOYMENT_FILE}

# Create or update subscription
EXISTING_SUB=$(ibmcloud sat subscription ls -q | grep "$SATELLITE_SUBSCRIPTION" || true)
if [ -z "${EXISTING_SUB}" ]; then
# if ! ibmcloud sat subscription get --subscription "$SATELLITE_SUBSCRIPTION" &>/dev/null ; then
  ibmcloud sat subscription create --name "$SATELLITE_SUBSCRIPTION" --group "$SATELLITE_CLUSTER_GROUP" --version "$SATELLITE_CONFIG_VERSION" --config "$SATELLITE_CONFIG"
else
  ibmcloud sat subscription update --subscription "$SATELLITE_SUBSCRIPTION" -f --group "$SATELLITE_CLUSTER_GROUP" --version "$SATELLITE_CONFIG_VERSION"
fi

echo -e "CHECKING deployment rollout"
set -x
ibmcloud sat subscription get --subscription "$SATELLITE_SUBSCRIPTION"
ibmcloud sat config get --config "$SATELLITE_CONFIG"
ibmcloud sat config version get --config "$SATELLITE_CONFIG" --version "$SATELLITE_CONFIG_VERSION"
ibmcloud sat config version get --config "$SATELLITE_CONFIG" --version "$SATELLITE_CONFIG_VERSION" --save-config 

ibmcloud sat resource ls --subscription $SATELLITE_SUBSCRIPTION
# TODO wait until resources have been updated with timestamp > version creation time 
# TODO check status of all deployed resources in subscription -- if all good then success
set +x

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
  DEPLOYMENT_ENVIRONMENT="${SATELLITE_CLUSTER_GROUP}:${CLUSTER_NAMESPACE}"
  ibmcloud doi publishdeployrecord --env $DEPLOYMENT_ENVIRONMENT \
    --buildnumber ${SOURCE_BUILD_NUMBER} --logicalappname="${APP_NAME:-$IMAGE_NAME}" --status ${STATUS}
fi
if [ "$STATUS" == "fail" ]; then
  echo "DEPLOYMENT FAILED"
  echo "Showing registry pull quota"
  ibmcloud cr quota || true
  exit 1
fi

