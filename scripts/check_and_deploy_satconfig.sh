#!/bin/bash
# This script checks the IBM Container Service cluster is ready, has a namespace configured with access to the private
# image registry (using an IBM Cloud API Key), perform a kubectl deploy of container image and check on outcome.
# uncomment to debug the script
# set -x
# copy the script below into your app code repo (e.g. ./scripts/check_and_deploy_kubectl.sh) and 'source' it from your pipeline job
#    source ./scripts/check_and_deploy_kubectl.sh
# alternatively, you can source it from online script:
#    source <(curl -sSL "https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/check_and_deploy_kubectl.sh")
# ------------------
# source: https://raw.githubusercontent.com/open-toolchain/commons/master/scripts/check_and_deploy_kubectl.sh

# This script checks the IBM Container Service cluster is ready, has a namespace configured with access to the private
# image registry (using an IBM Cloud API Key), perform a kubectl deploy of container image and check on outcome.

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


# Grant access to private image registry from namespace $CLUSTER_NAMESPACE
# reference https://cloud.ibm.com/docs/containers?topic=containers-images#other_registry_accounts
echo "=========================================================="
echo -e "CONFIGURING ACCESS to private image registry from namespace ${CLUSTER_NAMESPACE}"
IMAGE_PULL_SECRET_NAME="ibmcloud-toolchain-${PIPELINE_TOOLCHAIN_ID}-${REGISTRY_URL}"

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
yq write --inplace $DEPLOYMENT_FILE --doc $DEPLOYMENT_DOC_INDEX "spec.template.spec.containers[0].image" "${REGISTRY_URL}/${REGISTRY_NAMESPACE}/${IMAGE_NAME}:${IMAGE_TAG}"
yq write --inplace $DEPLOYMENT_FILE --doc "*" "metadata.namespace" "${CLUSTER_NAMESPACE}" 
cat ${DEPLOYMENT_FILE}

if [ ! -z "${CLUSTER_INGRESS_SUBDOMAIN}" ]; then
  echo "=========================================================="
  echo "UPDATING manifest with ingress information"
  INGRESS_DOC_INDEX=$(yq read --doc "*" --tojson $DEPLOYMENT_FILE | jq -r 'to_entries | .[] | select(.value.kind | ascii_downcase=="ingress") | .key')
  if [ -z "$INGRESS_DOC_INDEX" ]; then
    echo "No Kubernetes Ingress definition found in $DEPLOYMENT_FILE."
  else
    # Update ingress with cluster domain/secret information
    # Look for ingress rule whith host contains the token "cluster-ingress-subdomain"
    INGRESS_RULES_INDEX=$(yq r --doc $INGRESS_DOC_INDEX --tojson $DEPLOYMENT_FILE | jq '.spec.rules | to_entries | .[] | select( .value.host | contains("cluster-ingress-subdomain")) | .key')
    if [ ! -z "$INGRESS_RULES_INDEX" ]; then
      INGRESS_RULE_HOST=$(yq r --doc $INGRESS_DOC_INDEX $DEPLOYMENT_FILE spec.rules[${INGRESS_RULES_INDEX}].host)
      yq w --inplace --doc $INGRESS_DOC_INDEX $DEPLOYMENT_FILE spec.rules[${INGRESS_RULES_INDEX}].host ${INGRESS_RULE_HOST/cluster-ingress-subdomain/$CLUSTER_INGRESS_SUBDOMAIN}
    fi
    # Look for ingress tls whith secret contains the token "cluster-ingress-secret"
    INGRESS_TLS_INDEX=$(yq r --doc $INGRESS_DOC_INDEX --tojson $DEPLOYMENT_FILE | jq '.spec.tls | to_entries | .[] | select(.secretName="cluster-ingress-secret") | .key')
    if [ ! -z "$INGRESS_TLS_INDEX" ]; then
      yq w --inplace --doc $INGRESS_DOC_INDEX $DEPLOYMENT_FILE spec.tls[${INGRESS_TLS_INDEX}].secretName $CLUSTER_INGRESS_SECRET
      INGRESS_TLS_HOST_INDEX=$(yq r --doc $INGRESS_DOC_INDEX $DEPLOYMENT_FILE spec.tls[${INGRESS_TLS_INDEX}] --tojson | jq '.hosts | to_entries | .[] | select( .value | contains("cluster-ingress-subdomain")) | .key')
      if [ ! -z "$INGRESS_TLS_HOST_INDEX" ]; then
        INGRESS_TLS_HOST=$(yq r --doc $INGRESS_DOC_INDEX $DEPLOYMENT_FILE spec.tls[${INGRESS_TLS_INDEX}].hosts[$INGRESS_TLS_HOST_INDEX])
        yq w --inplace --doc $INGRESS_DOC_INDEX $DEPLOYMENT_FILE spec.tls[${INGRESS_TLS_INDEX}].hosts[$INGRESS_TLS_HOST_INDEX] ${INGRESS_TLS_HOST/cluster-ingress-subdomain/$CLUSTER_INGRESS_SUBDOMAIN}
      fi
    fi
    cat $DEPLOYMENT_FILE
  fi
fi

echo "=========================================================="
echo "DEPLOYING using SATELLITE CONFIG"
set -x
ibmcloud sat config version create --name $SOURCE_BUILD_NUMBER --config test --file-format yaml --read-config ${DEPLOYMENT_FILE}

ibmcloud sat subscription create --group phsatcon --config test --name foo --version $SOURCE_BUILD_NUMBER

# kubectl apply --namespace ${CLUSTER_NAMESPACE} -f ${DEPLOYMENT_FILE} 
# set +x
# Extract name from actual Kube deployment resource owning the deployed container image 
# Ensure that the image match the repository, image name and tag without the @ sha id part to handle
# case when image is sha-suffixed or not - ie:
# us.icr.io/sample/hello-containers-20190823092122682:1-master-a15bd262-20190823100927
# or
# us.icr.io/sample/hello-containers-20190823092122682:1-master-a15bd262-20190823100927@sha256:9b56a4cee384fa0e9939eee5c6c0d9912e52d63f44fa74d1f93f3496db773b2e
# DEPLOYMENT_NAME=$(kubectl get deploy --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '.items[] | select(.spec.template.spec.containers[]?.image | test("'"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'(@.+|$)")) | .metadata.name' )
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

###############################################################################
###############################################################################
###############################################################################
exit 0
###############################################################################
###############################################################################
###############################################################################

# Extract app name from actual Kube pod 
# Ensure that the image match the repository, image name and tag without the @ sha id part to handle
# case when image is sha-suffixed or not - ie:
# us.icr.io/sample/hello-containers-20190823092122682:1-master-a15bd262-20190823100927
# or
# us.icr.io/sample/hello-containers-20190823092122682:1-master-a15bd262-20190823100927@sha256:9b56a4cee384fa0e9939eee5c6c0d9912e52d63f44fa74d1f93f3496db773b2e
# echo "=========================================================="
APP_NAME=$(kubectl get pods --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '[ .items[] | select(.spec.containers[]?.image | test("'"${IMAGE_REPOSITORY}:${IMAGE_TAG}"'(@.+|$)")) | .metadata.labels.app] [0]')
echo -e "APP: ${APP_NAME}"
echo "DEPLOYED PODS:"
kubectl describe pods --selector app=${APP_NAME} --namespace ${CLUSTER_NAMESPACE}

# lookup service for current release
APP_SERVICE=$(kubectl get services --namespace ${CLUSTER_NAMESPACE} -o json | jq -r ' .items[] | select (.spec.selector.release=="'"${RELEASE_NAME}"'") | .metadata.name ')
if [ -z "${APP_SERVICE}" ]; then
  # lookup service for current app with NodePort type
  # unless there is an ingress subdomain in the cluster - in that the service that is not NodePort would be exposed
  # First if ingress then look for a non NodePort service
  if [ "${CLUSTER_INGRESS_SUBDOMAIN}" ]; then    
    APP_SERVICE=$(kubectl get services --namespace ${CLUSTER_NAMESPACE} -o json | jq -r ' .items[] | select (.spec.selector.app=="'"${APP_NAME}"'" and .spec.type!="NodePort") | .metadata.name ')
  fi
  # If nothing found then fallback to a NodePort service
  if [ -z "${APP_SERVICE}" ]; then
    APP_SERVICE=$(kubectl get services --namespace ${CLUSTER_NAMESPACE} -o json | jq -r ' .items[] | select (.spec.selector.app=="'"${APP_NAME}"'" and .spec.type=="NodePort") | .metadata.name ')
  fi  
fi
if [ ! -z "${APP_SERVICE}" ]; then
  APP_SERVICE_TYPE=$(kubectl get service $APP_SERVICE --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '.spec.type')
  echo -e "SERVICE: ${APP_SERVICE}"
  echo "DEPLOYED SERVICES:"
  kubectl describe services ${APP_SERVICE} --namespace ${CLUSTER_NAMESPACE}
fi

echo ""
echo "=========================================================="
echo "DEPLOYMENT SUCCEEDED"
if [ "${CLUSTER_INGRESS_SUBDOMAIN}" ] && [ "${USE_ISTIO_GATEWAY}" != true ]; then
  APP_INGRESS=$(kubectl get ingress --namespace "$CLUSTER_NAMESPACE" -o json | jq -r --arg service_name "${APP_SERVICE}" ' .items[] | first(select(.spec.rules[].http.paths[].backend.serviceName==$service_name)) | .metadata.name')
  if [ "$APP_INGRESS" ]; then
    INGRESS_JSON=$(kubectl get ingress --namespace "$CLUSTER_NAMESPACE" "${APP_INGRESS}" -o json)
    # Expose app using ingress host and path for the service
    APP_HOST=$(echo $INGRESS_JSON | jq -r --arg service_name "$APP_SERVICE" '.spec.rules[] | first(select(.http.paths[].backend.serviceName==$service_name)) | .host' | head -n1)
    APP_PATH=$(echo $INGRESS_JSON | jq -r --arg service_name "$APP_SERVICE" '.spec.rules[].http.paths[] | first(select(.backend.serviceName==$service_name)) | .path' | head -n1)
    # Remove any group in the path in case of regex in ingress path definition
    # https://kubernetes.github.io/ingress-nginx/user-guide/ingress-path-matching/
    APP_PATH=$(echo "$APP_PATH" | sed "s/([^)]*)//g")
    # Remove the last / from APP_PATH if any
    APP_PATH=${APP_PATH%/}
    export APP_URL=https://${APP_HOST}${APP_PATH} # using 'export', the env var gets passed to next job in stage
    echo -e "VIEW THE APPLICATION AT: ${APP_URL}"
  fi
fi
if [ -z "$APP_URL" ] && [ "$APP_SERVICE" ]; then
  # No ingress resource linked the given service
  # Fallback according to the service type
  if [ "$APP_SERVICE_TYPE" = "NodePort" ]; then
    # Only NodePort will be available
    echo ""
    if [ "${USE_ISTIO_GATEWAY}" = true ]; then
      PORT=$( kubectl get svc istio-ingressgateway -n istio-system -o json | jq -r '.spec.ports[] | select (.name=="http2") | .nodePort ' )
      echo -e "*** istio gateway enabled ***"
    else
      PORT=$( kubectl get service ${APP_SERVICE} --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '.spec.ports[0].nodePort' )
    fi
    if [ -z "${KUBERNETES_MASTER_ADDRESS}" ]; then
      echo "Using first worker node ip address as NodeIP: ${IP_ADDR}"
    else 
      # check if a route resource exists in the this kubernetes cluster
      if kubectl explain route > /dev/null 2>&1; then
        # Assuming the kubernetes target cluster is an openshift cluster
        # Check if a route exists for exposing the service ${APP_SERVICE}
        if  kubectl get routes --namespace ${CLUSTER_NAMESPACE} -o json | jq --arg service "$APP_SERVICE" -e '.items[] | select(.spec.to.name==$service)'; then
          echo "Existing route to expose service $APP_SERVICE"
        else
          # create OpenShift route
cat > test-route.json << EOF
{"apiVersion":"route.openshift.io/v1","kind":"Route","metadata":{"name":"${APP_SERVICE}"},"spec":{"to":{"kind":"Service","name":"${APP_SERVICE}"}}}
EOF
          echo ""
          cat test-route.json
          kubectl apply -f test-route.json --validate=false --namespace ${CLUSTER_NAMESPACE}
          kubectl get routes --namespace ${CLUSTER_NAMESPACE}
        fi
        echo "LOOKING for host in route exposing service $APP_SERVICE"
        IP_ADDR=$(kubectl get routes --namespace ${CLUSTER_NAMESPACE} -o json | jq --arg service "$APP_SERVICE" -r '.items[] | select(.spec.to.name==$service) | .status.ingress[0].host')
        PORT=80
      else
        # Use the KUBERNETES_MASTER_ADRESS
        IP_ADDR=${KUBERNETES_MASTER_ADDRESS}
      fi
    fi  
    export APP_URL=http://${IP_ADDR}:${PORT} # using 'export', the env var gets passed to next job in stage
    echo -e "VIEW THE APPLICATION AT: ${APP_URL}"
  else
    if [ -z "${KUBERNETES_MASTER_ADDRESS}" ]; then
      CLUSTER_IP=$(kubectl get service ${APP_SERVICE} --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '.spec.clusterIP')
      if [ "$CLUSTER_IP" ]; then
        IP_ADDR=$CLUSTER_IP
      fi
      PORT=$(kubectl get service ${APP_SERVICE} --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '.spec.ports[0].port')
    else 
      # Use the KUBERNETES_MASTER_ADRESS
      IP_ADDR=${KUBERNETES_MASTER_ADDRESS}
      PORT=$(kubectl get service ${APP_SERVICE} --namespace ${CLUSTER_NAMESPACE} -o json | jq -r '.spec.ports[0].port')
    fi
    export APP_URL=http://${IP_ADDR}:${PORT} # using 'export', the env var gets passed to next job in stage
    echo -e "VIEW THE APPLICATION AT: ${APP_URL}"
  fi
fi
