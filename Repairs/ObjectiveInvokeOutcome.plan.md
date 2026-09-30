# Repair: objective-invoke-outcome

## Diagnose

1. `scenario_port_bindings` - arguments: `request-capability-from-objective`, `request-capability-from-objective` - [../Catalog/Sql/scenario_port_bindings.sql](../Catalog/Sql/scenario_port_bindings.sql)

## Load

1. `definition_generations` - arguments: `sidefx:capability:request-capability-from-objective`, `TRANSFORMATION`, `shape-objective-invocation-result` - [../Catalog/Sql/definition_generations.sql](../Catalog/Sql/definition_generations.sql)

## Artifacts

- Document `shape-objective-invocation-result` -> [../Documents/ShapeObjectiveInvocationResultDocument.cs](../Documents/ShapeObjectiveInvocationResultDocument.cs)
- Operation `append-invoke-port` - arguments: `request-capability-from-objective`, `request-capability-from-objective.v1`, `request-capability-from-objective.shape`, `invoke-port`, `shape-objective-invocation-result-port`, `4863`, `112923` -> [../Operations/AppendInvokePortOperation.cs](../Operations/AppendInvokePortOperation.cs)

## Preserve

the seven existing operation links are carried to the new authority version unchanged (ordinal -> port_version compared before/after)

## Assert

the invoked variant is declared (every declared outcome variant is produced by exactly one branch; the shaping step cannot emit an undeclared outcome); the graph digest delta is scoped to the capability

