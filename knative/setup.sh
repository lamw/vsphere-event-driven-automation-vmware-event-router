#!/bin/bash

set -euo pipefail

VEBA_RELEASE=release-0.7.2
VEBA_BOM_FILE=veba-bom.json
KUBECTL_WAIT=10m

# Verify ytt is installed
command -v ytt >/dev/null 2>&1 || { echo >&2 "ytt is not installed, aborting"; exit 1; }

cecho() {
        local default_msg="No message passed."
        message=${1:-$default_msg}
        color=${2:-\E[32;40m}
        echo -e "\E[36;40m"
        echo "$message"
        tput sgr0

        return
}

cecho "Downloading VMware Event Broker Appliance BOM ..."
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/veba-bom.json -o veba-bom.json

cecho "Downloading Knative Eventing & Serving configuration files ..."
KNATIVE_SERVING_VERSION=$(jq -r < ${VEBA_BOM_FILE} '.["knative-serving"].gitRepoTag')
curl -L https://github.com/knative/serving/releases/download/knative-${KNATIVE_SERVING_VERSION}/serving-crds.yaml -o serving-crds.yaml
curl -L https://github.com/knative/serving/releases/download/knative-${KNATIVE_SERVING_VERSION}/serving-core.yaml -o serving-core.yaml

KNATIVE_EVENTING_VERSION=$(jq -r < ${VEBA_BOM_FILE} '.["knative-eventing"].gitRepoTag')
curl -L https://github.com/knative/eventing/releases/download/knative-${KNATIVE_EVENTING_VERSION}/eventing-crds.yaml -o eventing-crds.yaml
curl -L https://github.com/knative/eventing/releases/download/knative-${KNATIVE_EVENTING_VERSION}/eventing-core.yaml -o eventing-core.yaml

KNATIVE_CONTOUR_VERSION=$(jq -r < ${VEBA_BOM_FILE} '.["knative-contour"].gitRepoTag')
KNATIVE_CONTOUR_TEMPLATE=knative-contour-template.yaml
KNATIVE_CONTOUR_OVERLAY=knative-contour-overlay.yaml
KNATIVE_CONTOUR_CONFIG=knative-contour.yaml
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/files/downloads/knative-contour/overlay.yaml -o ${KNATIVE_CONTOUR_OVERLAY}
curl -L https://github.com/knative/net-contour/releases/download/knative-${KNATIVE_CONTOUR_VERSION}/contour.yaml -o ${KNATIVE_CONTOUR_TEMPLATE}
ytt -f ${KNATIVE_CONTOUR_OVERLAY} -f ${KNATIVE_CONTOUR_TEMPLATE} > ${KNATIVE_CONTOUR_CONFIG}
curl -L https://github.com/knative/net-contour/releases/download/knative-${KNATIVE_CONTOUR_VERSION}/net-contour.yaml -o net-contour.yaml

cecho "Downloading RabbitMQ Operator configuration files ..."
RABBITMQ_OPERATOR_VERSION=$(jq -r < ${VEBA_BOM_FILE} '.["rabbitmq-operator"].gitRepoTag')
RABBITMQ_OPERATOR_TEMPLATE=cluster-operator-template.yml
RABBITMQ_OPERATOR_OVERLAY=rabbitmq-operator-overlay.yaml
RABBITMQ_OPERATOR_CONFIG=cluster-operator.yml
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/files/downloads/rabbitmq-operator/overlay.yaml -o ${RABBITMQ_OPERATOR_OVERLAY}
curl -L https://github.com/rabbitmq/cluster-operator/releases/download/${RABBITMQ_OPERATOR_VERSION}/cluster-operator.yml -o ${RABBITMQ_OPERATOR_TEMPLATE}
ytt -f ${RABBITMQ_OPERATOR_OVERLAY} -f ${RABBITMQ_OPERATOR_TEMPLATE} > ${RABBITMQ_OPERATOR_CONFIG}

RABBITMQ_BROKER_VERSION=$(jq -r < ${VEBA_BOM_FILE} '.["rabbitmq-broker"].gitRepoTag')
curl -L https://github.com/knative-sandbox/eventing-rabbitmq/releases/download/knative-${RABBITMQ_BROKER_VERSION}/rabbitmq-broker.yaml -o rabbitmq-broker.yaml

RABBITMQ_MESSAGING_OPERATOR_VERSION=$(jq -r < ${VEBA_BOM_FILE} '.["rabbitmq-messaging-topology-operator"].gitRepoTag')
RABBITMQ_MESSAGING_OPERATOR_TEMPLATE=messaging-topology-operator-with-certmanager-template.yaml
RABBITMQ_MESSAGING_OPERATOR_OVERLAY=rabbitmq-messaging-operator-overlay.yaml
RABBITMQ_MESSAGING_OPERATOR_CONFIG=messaging-topology-operator-with-certmanager.yaml
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/files/downloads/rabbitmq-messaging-operator/overlay.yaml -o ${RABBITMQ_MESSAGING_OPERATOR_OVERLAY}
curl -L https://github.com/rabbitmq/messaging-topology-operator/releases/download/${RABBITMQ_MESSAGING_OPERATOR_VERSION}/messaging-topology-operator-with-certmanager.yaml -o ${RABBITMQ_MESSAGING_OPERATOR_TEMPLATE}
ytt -f ${RABBITMQ_MESSAGING_OPERATOR_OVERLAY} -f ${RABBITMQ_MESSAGING_OPERATOR_TEMPLATE} > ${RABBITMQ_MESSAGING_OPERATOR_CONFIG}

cecho "Downloading Certmanager configuration file ..."
CERT_MANAGER_VERSION=$(jq -r < ${VEBA_BOM_FILE} '.["cert-manager"].gitRepoTag')
CERT_MANAGER_TEMPLATE=cert-manager-template.yaml
CERT_MANAGER_OVERLAY=cert-manager-overlay.yaml
CERT_MANAGER_CONFIG=cert-manager.yaml
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/files/downloads/cert-manager/overlay.yaml -o ${CERT_MANAGER_OVERLAY}
curl -L https://github.com/jetstack/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml -o ${CERT_MANAGER_TEMPLATE}
ytt -f ${CERT_MANAGER_OVERLAY} -f ${CERT_MANAGER_TEMPLATE} > ${CERT_MANAGER_CONFIG}

cecho "Installing Knative Serving & Eventing ..."
kubectl apply -f serving-crds.yaml
kubectl apply -f serving-core.yaml
kubectl wait deployment --all --timeout=${KUBECTL_WAIT} --for=condition=Available -n knative-serving
kubectl apply -f knative-contour.yaml
kubectl apply -f net-contour.yaml
kubectl patch configmap/config-network --namespace knative-serving --type merge --patch '{"data":{"ingress.class":"contour.ingress.networking.knative.dev"}}'
kubectl wait deployment --all --timeout=${KUBECTL_WAIT} --for=condition=Available -n contour-external
kubectl wait deployment --all --timeout=${KUBECTL_WAIT} --for=condition=Available -n contour-internal

kubectl apply -f eventing-crds.yaml
kubectl apply -f eventing-core.yaml
kubectl wait pod --timeout=${KUBECTL_WAIT} --for=condition=Ready -l '!job-name' -n knative-eventing

cecho "Installing RabbitMQ Cluster Operator ..."
kubectl apply -f cluster-operator.yml

cecho "Installing Certmanager ..."
kubectl apply -f cert-manager.yaml
kubectl wait deployment --all --timeout=${KUBECTL_WAIT} --for=condition=Available -n cert-manager

cecho "Installing RabbitMQ Messaging Topology Operator ..."
kubectl apply -f messaging-topology-operator-with-certmanager.yaml
kubectl wait deployment --all --timeout=${KUBECTL_WAIT} --for=condition=Available -n rabbitmq-system

cecho "Installing RabbitMQ Broker ..."
kubectl apply -f rabbitmq-broker.yaml

cecho "Initializing RabbitMQ Broker ..."
RABBITMQ_CONFIG_TEMPLATE=rabbit-template.yaml
RABBITMQ_CONFIG=rabbit.yaml
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/files/configs/knative/templates/rabbit-template.yaml -o ${RABBITMQ_CONFIG_TEMPLATE}
ytt --data-value-file bom=${VEBA_BOM_FILE} -f ${RABBITMQ_CONFIG_TEMPLATE} > ${RABBITMQ_CONFIG}
kubectl create ns vmware-system
kubectl create ns vmware-functions
kubectl apply -f ${RABBITMQ_CONFIG}
kubectl wait broker default --timeout=${KUBECTL_WAIT} --for=condition=Ready -n vmware-functions

cecho "Installing Sockeye Event Viewer ..."
SOCKEYE_TEMPLATE=sockeye-template.yaml
SOCKEYE_CONFIG=sockeye.yaml
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/files/configs/knative/templates/sockeye-template.yaml -o ${SOCKEYE_TEMPLATE}
ytt --data-value-file bom=${VEBA_BOM_FILE} -f ${SOCKEYE_TEMPLATE} > ${SOCKEYE_CONFIG}
kubectl -n vmware-functions apply -f ${SOCKEYE_CONFIG}

cecho "Creating VMware Event Router Cluster Role ..."
curl -L https://raw.githubusercontent.com/vmware-samples/vcenter-event-broker-appliance/${VEBA_RELEASE}/files/configs/event-router/vmware-event-router-clusterrole.yaml -o vmware-event-router-clusterrole.yaml
kubectl apply -f vmware-event-router-clusterrole.yaml