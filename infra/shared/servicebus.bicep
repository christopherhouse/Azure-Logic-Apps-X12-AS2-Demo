// Azure Service Bus Standard Namespace
// Topic 'purchase-orders.received' with subscription 'all-messages' (no filter).
// Public network access enabled; TLS 1.2; diagnostics (allLogs + AllMetrics → LAW).

targetScope = 'resourceGroup'

@description('Service Bus namespace name')
param namespaceName string

@description('Location for Service Bus namespace')
param location string

@description('Resource tags')
param tags object = {}

@description('Log Analytics Workspace ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Topic name')
param topicName string = 'purchase-orders.received'

@description('Subscription name under the topic')
param subscriptionName string = 'all-messages'

// Service Bus namespace (Standard tier)
resource serviceBusNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: namespaceName
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: '1.2'
    disableLocalAuth: false // allow SAS for compat; managed identity is enforced via RBAC
  }
}

// Topic: purchase-orders.received
resource topic 'Microsoft.ServiceBus/namespaces/topics@2022-10-01-preview' = {
  name: topicName
  parent: serviceBusNamespace
  properties: {
    enablePartitioning: false
    enableBatchedOperations: true
  }
}

// Subscription: all-messages (no filter — receives every message published to the topic)
resource subscription 'Microsoft.ServiceBus/namespaces/topics/subscriptions@2022-10-01-preview' = {
  name: subscriptionName
  parent: topic
  properties: {
    enableBatchedOperations: true
    deadLetteringOnMessageExpiration: true
    maxDeliveryCount: 10
  }
}

// Diagnostics on the namespace (allLogs + AllMetrics → LAW)
resource serviceBusDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: serviceBusNamespace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output namespaceId string = serviceBusNamespace.id
output namespaceName string = serviceBusNamespace.name
output fullyQualifiedNamespace string = replace(replace(serviceBusNamespace.properties.serviceBusEndpoint, 'https://', ''), ':443/', '')
output topicName string = topic.name
output subscriptionName string = subscription.name
