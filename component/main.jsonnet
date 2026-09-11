// main template for solution-base-monitoring
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local inv = kap.inventory();
local prometheus = import 'lib/prometheus.libsonnet';
// The hiera parameters for the component
local params = inv.parameters.solution_base_monitoring;

local namespace = (
  if std.member(inv.applications, 'prometheus') then
    prometheus.RegisterNamespace(kube.Namespace(params.namespace))
  else if inv.parameters.facts.distribution == 'openshift4' then
    kube.Namespace(params.namespace) {
      metadata+: {
        labels+: { 'openshift.io/cluster-monitoring': 'true' },
      },
    }
  else
    kube.Namespace(params.namespace)
) + {
  metadata+: {
    labels+: params.namespaceLabels,
    annotations+: params.namespaceAnnotations,
  },
};

local defaultRuleLabels = {
  syn: 'true',
  syn_component: 'solution-base-monitoring',
  syn_team: '{{ $labels.label_syn_team }}',
};

local openshiftRules = std.parseJson(
  kap.yaml_load(
    local parts = std.split(std.thisFile, '/');
    std.join('/', parts[:std.length(parts) - 1]) + '/openshift-rules.yml'
  )
);

local monitor_namespaces = params.monitor_namespaces;
local namespaceLabelFilter = 'and on(namespace) kube_namespace_labels{label_%s="%s"}' % [
  monitor_namespaces.label,
  monitor_namespaces.label_value,
];
local teamJoin = '* on(namespace) group_left(label_syn_team) (max by (namespace, label_syn_team) (kube_namespace_labels))';

local ruleOverrides = params.prometheusRules;
local prometheusRules = std.mergePatch(openshiftRules.prometheusrule, ruleOverrides);

local alertNamePrefix = params.alertNamePrefix;
local renderAlertName(alertName) = alertNamePrefix + '_' + alertName;

local patchRule(alertName, r) =
  std.mergePatch(
    { alert: renderAlertName(alertName), labels: defaultRuleLabels },
     std.mergePatch(r, { expr: r.expr % ({
       namespaceLabelFilter: namespaceLabelFilter,
       teamJoin: teamJoin,
     } + params.thresholds) }),
  );

local buildManifest(manifestName, manifestData) = {
  apiVersion: 'monitoring.coreos.com/v1',
  kind: 'PrometheusRule',
  metadata: {
    name: manifestName,
    namespace: params.namespace,
  },
  spec: {
    groups: [
      local groupData = manifestData.spec.groups[groupName];
      {
        name: groupName,
        rules: [
          patchRule(alertName, groupData.rules[alertName])
          for alertName in std.objectFields(groupData.rules)
        ],
      }
      for groupName in std.objectFields(manifestData.spec.groups)
    ],
  },
};

{
  namespace: namespace,
} + {
  ['prometheusRule_%s' % manifestName]: buildManifest(manifestName, prometheusRules[manifestName])
  for manifestName in std.objectFields(prometheusRules)
}
