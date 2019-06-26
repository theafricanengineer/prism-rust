#!/bin/bash

LAUNCH_TEMPLATE=lt-02226ebae5fbef5f3

function start_instances
{
	# $1: number of instances to start
	if [ $# -ne 1 ]; then
		tput setaf 1
		echo "Required: number of instances to start"
		tput sgr0
		exit 1
	fi
	echo "Really?"
	select yn in "Yes" "No"; do
		case $yn in
			Yes ) break ;;
			No ) echo "Nothing happened."; exit ;;
		esac
	done
	echo "Launching $1 AWS EC2 instances"
	aws ec2 run-instances --launch-template LaunchTemplateId=$LAUNCH_TEMPLATE --count $1 > log/aws_start.log
	local instances=`jq -r '.Instances[].InstanceId ' log/aws_start.log`
	echo "Waiting for network interfaces to attach"
	sleep 3
	rm -f instances.txt
	rm -f ~/.ssh/config.d/prism
	echo "Querying public IPs and writing to SSH config"
	for instance in $instances ;
	do
		local ip=`aws ec2 describe-instances --instance-ids $instance | jq -r '.Reservations[0].Instances[0].PublicIpAddress'`
		local lan=`aws ec2 describe-instances --instance-ids $instance | jq -r '.Reservations[0].Instances[0].PrivateIpAddress'`
		echo "$instance,$ip,$lan" >> instances.txt
		echo "Host $instance" >> ~/.ssh/config.d/prism
		echo "    Hostname $ip" >> ~/.ssh/config.d/prism
		echo "    User ubuntu" >> ~/.ssh/config.d/prism
		echo "    IdentityFile ~/.ssh/prism.pem" >> ~/.ssh/config.d/prism
		echo "    StrictHostKeyChecking no" >> ~/.ssh/config.d/prism
		echo "    UserKnownHostsFile=/dev/null" >> ~/.ssh/config.d/prism
		echo "" >> ~/.ssh/config.d/prism
	done
	tput setaf 2
	echo "Instance started, SSH config written"
	tput sgr0
}

function fix_ssh_config
{
	local instances=`jq -r '.Instances[].InstanceId ' log/aws_start.log`
	rm -f instances.txt
	rm -f ~/.ssh/config.d/prism
	echo "Querying public IPs and writing to SSH config"
	for instance in $instances ;
	do
		local ip=`aws ec2 describe-instances --instance-ids $instance | jq -r '.Reservations[0].Instances[0].PublicIpAddress'`
		local lan=`aws ec2 describe-instances --instance-ids $instance | jq -r '.Reservations[0].Instances[0].PrivateIpAddress'`
		echo "$instance,$ip,$lan" >> instances.txt
		echo "Host $instance" >> ~/.ssh/config.d/prism
		echo "    Hostname $ip" >> ~/.ssh/config.d/prism
		echo "    User ubuntu" >> ~/.ssh/config.d/prism
		echo "    IdentityFile ~/.ssh/prism.pem" >> ~/.ssh/config.d/prism
		echo "    StrictHostKeyChecking no" >> ~/.ssh/config.d/prism
		echo "    UserKnownHostsFile=/dev/null" >> ~/.ssh/config.d/prism
		echo "" >> ~/.ssh/config.d/prism
	done
	tput setaf 2
	echo "SSH config written"
	tput sgr0
}

function stop_instances
{
	echo "Really?"
	select yn in "Yes" "No"; do
		case $yn in
			Yes ) break ;;
			No ) echo "Nothing happened."; exit ;;
		esac
	done
	local instances=`cat instances.txt`
	local instance_ids=""
	for instance in $instances ;
	do
		local id
		local ip
		local lan
		IFS=',' read -r id ip lan <<< "$instance"
		instance_ids="$instance_ids $id"
	done
	echo "Terminating instances $instance_ids"
	aws ec2 terminate-instances --instance-ids $instance_ids > log/aws_stop.log
	tput setaf 2
	echo "Instances terminated"
	tput sgr0
}

function build_prism
{
	echo "Copying local repository to build machine"
	rsync -ar ../Cargo.toml prism:~/prism/
	rsync -ar ../src prism:~/prism/
	rsync -ar ../.cargo prism:~/prism/
	echo "Building Prism binary"
	ssh prism -- 'cd ~/prism && /home/prism/.cargo/bin/cargo build --release' &> log/prism_build.log
	if [ $# -ne 1 ]; then
		echo "Stripping symbol"
		ssh prism -- 'cp /home/prism/prism/target/release/prism /home/prism/prism/target/release/prism-copy && strip /home/prism/prism/target/release/prism-copy'
	else
		if [ "$1" = "nostrip" ]; then
			ssh prism -- 'cp /home/prism/prism/target/release/prism /home/prism/prism/target/release/prism-copy'
		else
			echo "Stripping symbol"
			ssh prism -- 'cp /home/prism/prism/target/release/prism /home/prism/prism/target/release/prism-copy && strip /home/prism/prism/target/release/prism-copy'
		fi
	fi
	tput setaf 2
	echo "Finished"
	tput sgr0
}

function prepare_payload
{
	# $1: topology file to use
	if [ $# -ne 1 ]; then
		tput setaf 1
		echo "Required: topology file"
		tput sgr0
		exit 1
	fi
	echo "Deleting existing files"
	rm -rf payload
	rm -rf binary
	mkdir -p payload
	mkdir -p binary
	echo "Download binaries"
	scp prism:/home/prism/prism/target/release/prism-copy binary/prism
	local instances=`cat instances.txt`
	local instance_ids=""
	for instance in $instances ;
	do
		local id
		local ip
		local lan
		IFS=',' read -r id ip lan <<< "$instance"
		echo "Generating config files for $id"
		python3 scripts/gen_etcd_config.py $id $lan instances.txt
		echo "Copying binaries for $id"
		mkdir -p payload/$id
		cp -r binary payload/$id/binary
		mkdir -p payload/$id/scripts
		cp scripts/start-prism.sh payload/$id/scripts/start-prism.sh
		cp scripts/stop-prism.sh payload/$id/scripts/stop-prism.sh
	done
	python3 scripts/gen_prism_payload.py instances.txt $1
	tput setaf 2
	echo "Payload written"
	tput sgr0
}

function remove_payload_single
{
	ssh $1 -- 'rm -rf /home/ubuntu/payload'
}

function install_perf_single
{
	ssh $1 -- 'rm -f rustfilt && rm -rf FlameGraph && sudo apt-get update -y && sudo apt-get install linux-tools-aws linux-tools-4.15.0-1032-aws binutils -y && wget https://github.com/yangl1996/rustfilt/releases/download/1/rustfilt && git clone https://github.com/brendangregg/FlameGraph.git && chmod +x rustfilt && sudo apt-get install -y c++filt && echo export PATH=$PATH:/home/ubuntu:/home/ubuntu/FlameGraph >> /home/ubuntu/.profile'
}

function mount_tmpfs_single
{
	ssh $1 -- 'sudo rm -rf /tmp/prism && sudo mkdir -m 777 /tmp/prism && sudo mount -t tmpfs -o rw,size=20g tmpfs /tmp/prism'
}

function unmount_tmpfs_single
{
	ssh $1 -- 'sudo umount /tmp/prism && sudo rm -rf /tmp/prism'
}

function mount_nvme_single
{
	ssh $1 -- 'sudo rm -rf /tmp/prism && sudo mkdir -m 777 /tmp/prism && sudo mkfs -F -t ext4 /dev/nvme0n1 && sudo mount /dev/nvme0n1 /tmp/prism && sudo chmod 777 /tmp/prism'
}

function unmount_nvme_single
{
	ssh $1 -- 'sudo umount /tmp/prism && sudo rm -rf /tmp/prism'
}

function sync_payload_single
{
	rsync -rz payload/$1/ $1:/home/ubuntu/payload
}

function start_prism_single
{
	ssh $1 -- 'sudo mkdir -m 777 -p /tmp/prism && mkdir -p /home/ubuntu/log && bash /home/ubuntu/payload/scripts/start-prism.sh &>/home/ubuntu/log/start.log'
}

function stop_prism_single
{
	ssh $1 -- 'bash /home/ubuntu/payload/scripts/stop-prism.sh &>/home/ubuntu/log/stop.log'
}

function execute_on_all
{
	# $1: execute function '$1_single'
	# ${@:2}: extra params of the function
	local instances=`cat instances.txt`
	local pids=""
	for instance in $instances ;
	do
		local id
		local ip
		local lan
		IFS=',' read -r id ip lan <<< "$instance"
		echo "Executing $1 on $id"
		$1_single $id ${@:2} &>log/${id}_${1}.log &
		pids="$pids $!"
	done
	echo "Waiting for all jobs to finish"
	for pid in $pids ;
	do
		wait $pid
	done
	tput setaf 2
	echo "Finished"
	tput sgr0
}

function get_performance_single
{
	curl -s http://$3:$4/telematics/snapshot
}

function start_transactions_single
{
	curl -s "http://$3:$4/transaction-generator/set-arrival-distribution?interval=50&distribution=uniform"
	curl -s "http://$3:$4/transaction-generator/set-value-distribution?min=100&max=100&distribution=uniform"
	curl -s "http://$3:$4/transaction-generator/start?throttle=8000"
}

function start_mining_single
{
	curl -s "http://$3:$4/miner/start?lambda=45000&lazy=false"
}

function stop_transactions_single
{
	curl -s "http://$3:$4/transaction-generator/stop"
}

function stop_mining_single
{
	curl -s "http://$3:$4/miner/step"
}

function query_api 
{
	# $1: which data to get, $2: delay between nodes
	mkdir -p data
	local nodes=`cat nodes.txt`
	local pids=''
	for node in $nodes; do
		local name
		local host
		local pubip
		local apiport
		IFS=',' read -r name host pubip _ _ apiport _ <<< "$node"
		$1_single $name $host $pubip $apiport > "data/${name}_$1.txt" &
		pids="$pids $!"
		if [ "$2" -ne "0" ]; then
			sleep $2
		fi
	done
	for pid in $pids; do
		wait $pid
	done
}

function run_on_all
{
	# $@: command to run
	local instances=`cat instances.txt`
	local pids=""
	for instance in $instances ;
	do
		local id
		local ip
		local lan
		IFS=',' read -r id ip lan <<< "$instance"
		echo "Job launched for $id"
		ssh $id -- "$@" &
		pids="$pids $!"
	done
	echo "Waiting for all jobs to finish"
	for pid in $pids ;
	do
		wait $pid
	done
	tput setaf 2
	echo "Finished"
	tput sgr0
}

function ssh_to_server
{
	# $1: which server to ssh to (starting from 1)
	if [ $# -ne 1 ]; then
		tput setaf 1
		echo "Required: the index of server to SSH to"
		tput sgr0
		exit 1
	fi
	local instance=`sed -n "$1 p" < instances.txt`
	local id
	local ip
	local lan
	IFS=',' read -r id ip lan <<< "$instance"
	tput setaf 2
	echo "SSH to $id at $ip"
	tput sgr0
	ssh $id
}

function scp_from_server
{
	# $1: server, $2: src path, $3: dst path
	if [ $# -ne 3 ]; then
		tput setaf 1
		echo "Required: the index of server, src path and dst path"
		tput sgr0
		exit 1
	fi
	local instance=`sed -n "$1 p" < instances.txt`
	local id
	local ip
	local lan
	IFS=',' read -r id ip lan <<< "$instance"
	cmd_to_run="scp -r ${id}:${2} $3"
	tput setaf 2
	echo "Executing $cmd_to_run"
	tput sgr0
	scp -r ${id}:${2} $3
}

function read_log
{
	local nodes=`cat nodes.txt`
	local pids=''
	for node in $nodes; do
		local name
		local host
		local pubip
		local apiport
		IFS=',' read -r name host pubip _ _ apiport _ <<< "$node"
		if [ $name == $1 ]; then
			ssh $host -- cat "/home/ubuntu/log/$name.log" | less
		fi
	done
}

function show_visualization
{
	local nodes=`cat nodes.txt`
	local pids=''
	for node in $nodes; do
		local name
		local host
		local pubip
		local visport 
		IFS=',' read -r name host pubip _ _ _ visport <<< "$node"
		if [ $name == $1 ]; then
			open "http://$pubip:$visport/"
		fi
	done
}

function show_performance
{
	local nodes=`cat nodes.txt`
	local pids=''
	for node in $nodes; do
		local name
		local host
		local pubip
		local visport 
		IFS=',' read -r name host pubip _ _ apiport _ <<< "$node"
		if [ $name == $1 ]; then
			curl "http://$pubip:$apiport/telematics/snapshot"
		fi
	done
}

function start_prism
{
	execute_on_all start_prism
	start_time=`date +%s`
}

function stop_prism
{
	execute_on_all stop_prism
	stop_time=`date +%s`
	echo "STOP $stop_time" >> experiment.txt
}

function run_experiment
{
	echo "Starting Prism nodes"
	start_prism
	echo "All nodes started, starting transaction generation"
	query_api start_transactions 0
	query_api start_mining 0
	rm -f experiment.txt
	echo "START $start_time" >> experiment.txt
	echo "Running experiment"
}

mkdir -p log
case "$1" in
	help)
		cat <<- EOF
		Helper script to run Prism distributed tests

		Manage AWS EC2 Instances

		  start-instances n     Start n EC2 instances
		  stop-instances        Terminate EC2 instances
		  install-tools         Install tools
		  fix-config            Fix SSH config
		  mount-ramdisk         Mount RAM disk
		  unmount-ramdisk       Unmount RAM disk
		  mount-nvme            Mount NVME 
		  unmount-nvme          Unmount NVME

		Run Experiment

		  gen-payload topo      Generate scripts and configuration files
		  build [nostrip]	Build the Prism client binary
		  sync-payload          Synchronize payload to remote servers
		  start-prism           Start Prism nodes on each remote server
		  stop-prism            Stop Prism nodes on each remote server
		  run-exp               Run the experiment
		  stop-tx               Stop generating transactions
		  stop-mine             Stop mining

		Collect Data
		  
		  get-perf              Get performance data
		  show-vis              Open the visualization page for the given node

		Connect to Testbed

		  run-all cmd           Run command on all instances
		  ssh i                 SSH to the i-th server (1-based index)
		  scp i src dst         Copy file from remote
		  read-log node         Read the log of the given node
		EOF
		;;
	start-instances)
		start_instances $2 ;;
	stop-instances)
		stop_instances ;;
	fix-config)
		fix_ssh_config ;;
	mount-ramdisk)
		execute_on_all mount_tmpfs ;;
	unmount-ramdisk)
		execute_on_all unmount_tmpfs ;;
	mount-nvme)
		execute_on_all mount_nvme ;;
	unmount-nvme)
		execute_on_all unmount_nvme ;;
	install-tools)
		execute_on_all install_perf ;;
	gen-payload)
		prepare_payload $2 ;;
	build)
		build_prism $2 ;;
	sync-payload)
		execute_on_all remove_payload
		execute_on_all sync_payload ;;
	start-prism)
		start_prism ;;
	stop-prism)
		stop_prism ;;
	run-exp)
		run_experiment ;;
	stop-tx)
		query_api stop_transactions 0 ;;
	stop-mine)
		query_api stop_mining 0 ;;
	get-perf)
		show_performance $2 ;;
	show-vis)
		show_visualization $2 ;;
	run-all)
		run_on_all "${@:2}" ;;
	ssh)
		ssh_to_server $2 ;;
	scp)
		scp_from_server $2 $3 $4 ;;
	read-log)
		read_log $2 ;;
	*)
		tput setaf 1
		echo "Unrecognized subcommand '$1'"
		tput sgr0 ;;
esac
