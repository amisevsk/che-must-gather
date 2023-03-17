# Debugging scripts for Eclipse Che and OpenShift Dev Spaces

This repository contains scripts useful in debugging installations of Eclipse Che or OpenShift Dev Spaces in Kubernetes and OpenShift clusters.

## get-debug-info.sh
This script collects information useful when submitting a bug report. It gathers
* Pod, Deployment, Service, ConfigMap, Route/Ingress specs for the DevWorkspace and Eclipse Che or Dev Spaces Operators
* Pod, Deployment, Service, ConfigMap, Route/Ingress specs for any objects owned by a CheCluster CR on the cluster
* Logs for all involved pods
* (Optionally) Information about a specific workspace on the cluster

This script requires `kubectl` and `jq`. If `oc` is installed, it will be used to get the OpenShift version for OpenShift clusters.

Data is output into the following folder structure (names are different if Dev Spaces is installed instead of Eclipse Che):
```bash
che-debug-<timestamp>
├── checluster                # Information about the CheCluster
│   ├── che                   # Server logs, deployment, and service spec
│   ├── che-dashboard         # Dashboard logs, deployment, and service spec
│   ├── che-gateway           # Gateway logs, deployment, and service spec
│   ├── devfile-registry      # Devfile registry logs, deployment, and service spec
│   └── plugin-registry       # Devfile registry logs, deployment, and service spec
├── devworkspaces             # Information about the DevWorkspace (if specified)
└── operators
    ├── che-operator          # Information about Che Operator install
    └── devworkspace-operator # Information about DevWorkspace Operator install
```

### Usage:
* Basic: Output information about the current install to a directory
    ```bash
    ./get-debug-info.sh
    ```
* Get information about a specific workspace:
    ```bash
    ./get-debug-info.sh \
      --workspace-name <NAME>
      --workspace-namespace <NAMESPACE>
    ```
    This will add an additional folder named `devworkspaces` to the output directory, containing information the specified workspace
* Debug a workspace that fails to start:
    ```bash
    ./get-debug-info.sh \
      --workspace-name <NAME>
      --workspace-namespace <NAMESPACE>
      --debug-workspace-start
    ```
    This will add a debug annotation to the workspace and attempt to start it before gathering info. This is useful if a workspace has failed to start, as it allows gathering logs for failing pods, etc.
* Explictly specify namespace for `CheCluster`:
    ```bash
    ./get-debug-info.sh --checluster-namespace <NAMESPACE>
    ```
    This is useful for clusters where the current credentials do not have permissions to list CheClusters cluster-wide (e.g. if the user is a dedicated-admin).

### Additional arguments:
* `--dest-dir, -d <DIRECTORY>`: output to `<DIRECTORY>` instead of default
* `--zip, -z`: zip output directory to a file, for easier sharing. File will be named `che-debug.zip` or `devspaces-debug.zip`, depending on whether Eclipse Che or OpenShift Dev Spaces is installed.
