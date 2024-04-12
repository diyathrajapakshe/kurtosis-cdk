prometheus_package = import_module(
    "github.com/kurtosis-tech/prometheus-package/main.star"
)
grafana_package = import_module("github.com/kurtosis-tech/grafana-package/main.star")

service_package = import_module("./lib/service.star")
bridge_package = import_module("./cdk_bridge_infra.star")


def start_panoptichain(plan, args):
    # Create the panoptichain config.
    panoptichain_config_template = read_file(
        src="./templates/observability/panoptichain-config.yml"
    )
    contract_setup_addresses = service_package.get_contract_setup_addresses(plan, args)
    panoptichain_config_artifact = plan.render_templates(
        name="panoptichain-config",
        config={
            "config.yml": struct(
                template=panoptichain_config_template,
                data={
                    "l1_rpc_url": args["l1_rpc_url"],
                    "zkevm_rpc_url": args["zkevm_rpc_url"],
                    "l1_chain_id": args["l1_chain_id"],
                    "zkevm_rollup_chain_id": args["zkevm_rollup_chain_id"],
                }
                | contract_setup_addresses,
            )
        },
    )

    # Start panoptichain.
    return plan.add_service(
        name="panoptichain" + args["deployment_suffix"],
        config=ServiceConfig(
            image=args["panoptichain_image"],
            ports={
                "prometheus": PortSpec(9090, application_protocol="http"),
            },
            files={"/etc/panoptichain": panoptichain_config_artifact},
        ),
    )


def run(plan, args):
    services = []
    service_names = [
        "zkevm-agglayer",
        "zkevm-node-aggregator",
        "zkevm-node-eth-tx-manager",
        "zkevm-node-l2-gas-pricer",
        "zkevm-node-rpc",
        "zkevm-node-rpc-pless",
        "zkevm-node-sequence-sender",
        "zkevm-node-sequencer",
        "zkevm-node-synchronizer",
        "zkevm-node-synchronizer-pless",
    ]

    for name in service_names:
        service = plan.get_service(name=name + args["deployment_suffix"])

        if not service:
            continue

        services.append(service)
        if name == "zkevm-node-rpc":
            args["zkevm_rpc_url"] = "http://{}:{}".format(
                service.ip_address, service.ports["http-rpc"].number
            )

    # Start panoptichain.
    services.append(start_panoptichain(plan, args))

    metrics_jobs = [
        {
            "Name": service.name,
            "Endpoint": "{0}:{1}".format(
                service.ip_address,
                service.ports["prometheus"].number,
            ),
        }
        for service in services
    ]

    # Start prometheus.
    prometheus_url = prometheus_package.run(
        plan,
        metrics_jobs,
        name="prometheus" + args["deployment_suffix"],
    )

    # Start grafana.
    grafana_package.run(
        plan,
        prometheus_url,
        "github.com/0xPolygon/kurtosis-cdk/static-files/dashboards",
        name="grafana" + args["deployment_suffix"],
    )
