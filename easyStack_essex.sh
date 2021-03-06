#!/bin/sh
HOSTNAME="OS-NODE1"
IPADDR="127.0.0.1"
SCRIPT="easyStack.sh"
COMMAND=`pwd`"/$SCRIPT"
KEYPAIR="Mykey"
TIME_SRV="133.100.11.8"
ZONE="Asia/Shanghai"

## 选择虚拟技术，裸机使用kvm，虚拟机里面使用qemu
VIRT_TYPE="kvm"

###  user|pass|role|tenant
ADMIN_SETTING="admin|admin_secret|admin|admin"
SYSTEM_COMPONENT="nova|nova_secret|admin|service glance|glance_secret|admin|service swift|swift_secret|admin|service"
REGION="HZ_CN"
KEYS_ADMIN_URL="$IPADDR:35357/v2.0"
KEYS_URL="$IPADDR:5000/v2.0"
IMAGE_URL="$IPADDR:9292/v1"
EC2_URL="$IPADDR:8773/services/Cloud"
NOVA_URL="$IPADDR:8774/v2/\$(tenant_id)s"
VOLUME_URL="$IPADDR:8776/v1/\$(tenant_id)s"
OBG_STORE_URL="$IPADDR:8080/v1/AUTH_\$(tenant_id)s"

### Color setting
RED_COL="\\033[1;31m"  # red color
GREEN_COL="\\033[32;1m"     # green color
BLUE_COL="\\033[34;1m"    # blue color
YELLOW_COL="\\033[33;1m"         # yellow color
NORMAL_COL="\\033[0;39m"

###
KS_DIR="/var/lib/keystone"
KS_RCONFIG="$KS_DIR/ks_rc_"
KS_TOKEN_PRE="$KS_DIR/ks_token_"
KS_USER_PRE="$KS_DIR/ks_userid_"
KS_ROLE_PRE="$KS_DIR/ks_roleid_"
KS_TENANT_PRE="$KS_DIR/ks_tenantid_"
########################### function begin ##########################
ADMIN_USER=`echo $ADMIN_SETTING|cut -d"|" -f1`
ADMIN_PASS=`echo $ADMIN_SETTING|cut -d"|" -f2`
ADMIN_ROLE=`echo $ADMIN_SETTING|cut -d"|" -f3`
TENANT_NAME=`echo $ADMIN_SETTING|cut -d"|" -f4`

###
if [ `whoami` != "root" ]; then
	echo "You should be as root."
fi

env_initalize(){
### install kvm virtual software
#rpm -Uvh http://download.fedoraproject.org/pub/epel/6/i386/epel-release-6-7.noarch.rpm
rpm -Uvh http://mirrors.ustc.edu.cn/fedora/epel/6/x86_64/epel-release-6-8.noarch.rpm
yum -y install qemu-kvm qemu-kvm-tools kvm virt-manager libvirt libvirt-python python-virtinst libvirt-client bridge-utils dnsmasq-utils
### install openstack software
yum --enablerepo=epel-testing install \
	openstack-nova openstack-nova-novncproxy openstack-nova-consoleauth \
	openstack-glance openstack-keystone openstack-dashboard \
	openstack-quantum openstack-swift\* openstack-utils \
	python-pip python-tempita memcached qpid-cpp-server ntp ntpdate mysql-server

###
hostname  $HOSTNAME
sed -r -i "s:HOSTNAME=.*:HOSTNAME=$HOSTNAME:g" /etc/sysconfig/network
sed -r -i "/$HOSTNAME/d" /etc/hosts
echo "$IPADDR	$HOSTNAME" >> /etc/hosts

sed -r -i 's:timeout=.*:timeout=5:' /boot/grub/menu.lst
grep -q "elevator=deadline" /boot/grub/menu.lst
[ $? = 0 ] || sed -r -i '/^[^#]kernel/s:(.*):\1 enforcing=0 highres=off elevator=deadline:' /boot/grub/menu.lst

sed -r -i 's/^\s*#(net\.ipv4\.ip_forward=1.*)/\1/' /etc/sysctl.conf
echo 1 > /proc/sys/net/ipv4/ip_forward

sed -r -i '/redhat_transparent_hugepage/d' /etc/rc.local
cat >> /etc/rc.local <<EOF
echo yes > /sys/kernel/mm/redhat_transparent_hugepage/khugepaged/defrag
echo always > /sys/kernel/mm/redhat_transparent_hugepage/enabled
echo never > /sys/kernel/mm/redhat_transparent_hugepage/defrag
EOF
echo yes > /sys/kernel/mm/redhat_transparent_hugepage/khugepaged/defrag
echo always > /sys/kernel/mm/redhat_transparent_hugepage/enabled
echo never > /sys/kernel/mm/redhat_transparent_hugepage/defrag

###
setenforce 0
sed -r -i '/^SELINUX=/s:.*:SELINUX=disabled:' /etc/sysconfig/selinux
sed -r -i '/^SELINUX=/s:.*:SELINUX=disabled:' /etc/selinux/config
### 
sed -r -i '/auth/s:.*:auth=no:g' /etc/qpidd.conf
###
sed -r -i 's/#mdns_adv = 0/mdns_adv = 0/' /etc/libvirt/libvirtd.conf
sed -r -i 's/#auth_unix_rw/auth_unix_rw/' /etc/libvirt/libvirtd.conf
sed -r -i 's:^#fudge:fudge:g' /etc/ntp.conf
sed -r -i 's:^#server.*127.127.1.0:server 127.127.1.0:g' /etc/ntp.conf
 
### set timezone and language
grep -w -q $ZONE /etc/sysconfig/clock
if [ $? = 1 ];then
        sed -r -i "s:ZONE=.*:ZONE=\"$ZONE\":" /etc/sysconfig/clock
        cp -a /usr/share/zoneinfo/$ZONE /etc/localtime
fi

ntpdate -o3 $TIME_SRV

sed -r -i '/nofile/d' /etc/security/limits.conf
echo '* soft nofile 655350' >> /etc/security/limits.conf
echo '* hard nofile 655350' >> /etc/security/limits.conf
echo '#* soft memlock 104857' >> /etc/security/limits.conf
echo '#* hard memlock 104857' >> /etc/security/limits.conf

virsh net-autostart default --disable
virsh net-destroy default
###
for svc in  httpd mysqld libvirtd ntpd qpidd messagebus ntpd;do
	chkconfig $svc on && service $svc restart
done
}

keystone_init(){
openstack-db --service keystone --init

openssl rand -hex 10 > $KS_TOKEN_PRE$ADMIN_USER

cat > $KS_RCONFIG$ADMIN_USER <<EOF
export ADMIN_TOKEN=$(cat $KS_TOKEN_PRE$ADMIN_USER)
export OS_USERNAME=$ADMIN_USER
export OS_PASSWORD=$ADMIN_PASS
export OS_TENANT_NAME=$TENANT_NAME
export OS_AUTH_URL=http://127.0.0.1:5000/v2.0/
export SERVICE_ENDPOINT=http://127.0.0.1:35357/v2.0/
export SERVICE_TOKEN=$(cat $KS_TOKEN_PRE$ADMIN_USER)
EOF
source $KS_RCONFIG$ADMIN_USER
openstack-config --set /etc/keystone/keystone.conf DEFAULT admin_token $(cat $KS_TOKEN_PRE$ADMIN_USER)
sed -r -i '/OS_/d' ~/.bashrc
sed -r -i '/_TOKEN/d' ~/.bashrc
sed -r -i '/SERVICE_/d' ~/.bashrc
cat $KS_RCONFIG$ADMIN_USER >> ~/.bashrc
sed -r -i '/setenforce/d' ~/.bashrc
cat "setenforce 0" >> ~/.bashrc

chkconfig openstack-keystone on && service openstack-keystone restart
sleep 5
 
echo $ADMIN_ROLE >> /tmp/sys_role
echo $TENANT_NAME >> /tmp/sys_tenant

for item in $SYSTEM_COMPONENT;do
	role=`echo $item|cut -d"|" -f3`	
	tenant=`echo $item|cut -d"|" -f4`	
	echo $role >> /tmp/sys_role
	echo $tenant >> /tmp/sys_tenant
done
echo "admin" >> /tmp/sys_role
echo "Member" >> /tmp/sys_role
echo "admin" >> /tmp/sys_tenant
echo "service" >> /tmp/sys_tenant
ROLE=`sort -u /tmp/sys_role`
TENANT=`sort -u /tmp/sys_tenant`

for role in $ROLE;do
	printf "${GREEN_COL}%-15s\t${NORMAL_COL}" $role
	$COMMAND keys_addrole $role
done
echo

for tenant in $TENANT;do
	printf "${GREEN_COL}%-15s\t${NORMAL_COL}" $tenant
	$COMMAND keys_addtenant $tenant
done
echo

for item in "$ADMIN_USER|$ADMIN_PASS|$ADMIN_ROLE|$TENANT_NAME" $SYSTEM_COMPONENT;do
	user=`echo $item|cut -d"|" -f1`	
	pass=`echo $item|cut -d"|" -f2`	
	role=`echo $item|cut -d"|" -f3`	
	tenant=`echo $item|cut -d"|" -f4`	
	printf "${GREEN_COL}%-15s\t${NORMAL_COL}" $user
	$COMMAND keys_adduser $user $pass
	printf "${GREEN_COL}%15s\t${NORMAL_COL}" "------->"
	$COMMAND keys_bind $user $role $tenant
	echo
done
rm -rf /tmp/sys_*

### create default service
	$COMMAND keys_addsrv nova compute 'OpenStack Compute Service'
        $COMMAND keys_addsrv volume volume 'OpenStack Volume Service'
        $COMMAND keys_addsrv glance image  'OpenStack Image Service'
        $COMMAND keys_addsrv swift  object-store 'OpenStack Storage Service'
        $COMMAND keys_addsrv keystone identity 'OpenStack Identity Service'
        $COMMAND keys_addsrv ec2 ec2 'EC2 Service'
###
	$COMMAND keys_addept compute "http://$NOVA_URL"
	$COMMAND keys_addept volume "http://$VOLUME_URL"
	$COMMAND keys_addept object-store "http://$OBG_STORE_URL"
	$COMMAND keys_addept image "http://$IMAGE_URL"
	$COMMAND keys_addept ec2 "http://$EC2_URL"
	
	service_id=$(keystone service-list|awk -F'|' '/identity/{print $2}')
	keystone endpoint-create --region $REGION --service_id $service_id --publicurl http://$KEYS_URL --internalurl http://$KEYS_URL --adminurl http://$KEYS_ADMIN_URL
}

keystone_add_user(){
	if [ $# -ne 3 ];then
		echo "$SCRIPT keys_adduser user password"
	else
		user_name=$2
		user_pass=$3
		keystone user-create --name $user_name --pass $user_pass > $KS_USER_PRE$user_name
		user_id=$(awk -F'|' '/id/{print $3}' $KS_USER_PRE$user_name)
		echo -e "${YELLOW_COL}User added ID: $user_id ${NORMAL_COL}"
	fi
}

keystone_add_role(){
        if [ $# -ne 2 ];then
                echo "$SCRIPT keys_addrole role"
        else
                user_name=$2
                keystone role-create --name $user_name > $KS_ROLE_PRE$user_name
                role_id=$(awk -F'|' '/id/{print $3}' $KS_ROLE_PRE$user_name)
		echo -e "${YELLOW_COL}Role added ID: $role_id ${NORMAL_COL}"
        fi
}

keystone_add_tenant(){
        if [ $# -ne 2 ];then
                echo "$SCRIPT keys_addtenant tenant"
        else
                user_name=$2
                keystone tenant-create --name $user_name > $KS_TENANT_PRE$user_name
                tenant_id=$(awk -F'|' '/id/{print $3}' $KS_TENANT_PRE$user_name)
                echo -e "${YELLOW_COL}Tenant added ID: $tenant_id ${NORMAL_COL}"
        fi
}

keystone_list(){
        if [ $# -ne 2 ];then
                echo "$SCRIPT keys_list user|role|tenant|service|endpoint"
        else
                user_name=$2
		if [ $user_name = "all" ];then
			for i in user role tenant service;do
				echo -e "${YELLOW_COL}********************   $i List   ********************${NORMAL_COL}"
				keystone $i-list
				echo
			done
		else
			echo -e "${YELLOW_COL}********************   $user_name List   *********************${NORMAL_COL}"
                	keystone "$user_name"-list
		fi
        fi
}

keystone_user_role(){
       if [ $# -ne 4 ];then
                echo "$SCRIPT keys_bind user role tenant"
       else
                user_name=$2
                role_name=$3
		tenant_name=$4
		user_id=$(keystone user-list|awk -F'|' '/'"$user_name"'/{print $2}')
		role_id=$(keystone role-list|awk -F'|' '/'"$role_name"'/{print $2}')
		tenant_id=$(keystone tenant-list|awk -F'|' '/'"$tenant_name"'/{print $2}')
                STRING="keystone user-role-add \
                        --user-id $user_id \
                        --role-id $role_id \
                        --tenant_id $tenant_id "
                eval $STRING
		echo -e "${YELLOW_COL}User-Role-Tenant added successful.${NORMAL_COL}"
        fi

}

keystone_add_service(){
	if [ $# -ne 4 ];then
		echo "$SCRIPT keys_addsrv service type desc"
	else
		service_name=$2
		type=$3
		desc=$4
		keystone service-list|grep -q $service_name
		[ $? = 0 ] || keystone service-create --name $service_name --type $type --description "$desc"
	fi
}

keystone_add_endpoint(){
	if [ $# -ne 3 ];then
		echo "$SCRIPT keys_addept service url"
	else
		service_name=$2
		url=$3
		service_id=$(keystone service-list|awk -F'|' '/'"$service_name"'/{print $2}')
		STRING="keystone endpoint-create --region $REGION --service_id $service_id --publicurl '$url' --adminurl '$url' --internalurl '$url'"
		eval $STRING
	fi
}

glance_init(){
openstack-db --service glance --init

openstack-config --set /etc/glance/glance-api.conf paste_deploy flavor keystone
openstack-config --set /etc/glance/glance-registry.conf paste_deploy flavor keystone

#openstack-config --set /etc/glance/glance-api-paste.ini filter:authtoken admin_tenant_name service
#openstack-config --set /etc/glance/glance-api-paste.ini filter:authtoken admin_user glance
#openstack-config --set /etc/glance/glance-api-paste.ini filter:authtoken admin_password glance
openstack-config --set /etc/glance/glance-api-paste.ini filter:authtoken admin_token $(cat $KS_TOKEN_PRE$ADMIN_USER)

#openstack-config --set /etc/glance/glance-registry-paste.ini filter:authtoken admin_tenant_name service
#openstack-config --set /etc/glance/glance-registry-paste.ini filter:authtoken admin_user glance
#openstack-config --set /etc/glance/glance-registry-paste.ini filter:authtoken admin_password glance
openstack-config --set /etc/glance/glance-registry-paste.ini filter:authtoken admin_token $(cat $KS_TOKEN_PRE$ADMIN_USER)

for svc in registry api;do
	chkconfig openstack-glance-$svc on && service openstack-glance-$svc restart
done
}

glance_add_image(){
	if [ $# -ne 3 ];then
		echo "$SCRIPT gls_add image_desc image_filename"
	else
		desc="$2"
		filename=$3
		FORMAT="container_format=bare disk_format=raw"
		file $filename | grep -q -i 'qcow'
		[ $? = 0 ] && FORMAT="container_format=ovf disk_format=qcow2"
		file $filename | grep -q -i 'iso'
		[ $? = 0 ] && FORMAT="container_format=ovf disk_format=iso"
		STRING="glance add name=\"$desc\" is_public=true $FORMAT < $filename"
		eval $STRING
	fi
}

glance_list_image(){
	glance image-list
}

glance_show_image(){
	if [ $# -ne 2 ];then
		echo "$SCRIPT gls_show image_id"
	else
		glance image-show $2
	fi
}

nova_init(){
openstack-db --service nova --init
#dd if=/dev/zero of=/var/lib/nova/nova-volumes.img bs=1M seek=20k count=0
#vgcreate nova-volumes $(losetup --show -f /var/lib/nova/nova-volumes.img)
#openstack-config --set /etc/nova/nova.conf DEFAULT flat_interface eth0
#openstack-config --set /etc/nova/nova.conf DEFAULT public_interface eth0

openstack-config --set /etc/nova/nova.conf DEFAULT auth_strategy keystone
openstack-config --set /etc/nova/nova.conf DEFAULT connection_type libvirt
openstack-config --set /etc/nova/nova.conf DEFAULT libvirt_type $VIRT_TYPE
#openstack-config --set /etc/nova/api-paste.ini filter:authtoken admin_tenant_name service
#openstack-config --set /etc/nova/api-paste.ini filter:authtoken admin_user nova
#openstack-config --set /etc/nova/api-paste.ini filter:authtoken admin_password nova
openstack-config --set /etc/nova/api-paste.ini filter:authtoken admin_token  $(cat $KS_TOKEN_PRE$ADMIN_USER)

#network_manager = nova.network.manager.FlatDHCPManager
#iscsi_helper = tgtadm
#public_interface = eth0                    #WAN 接口
#flat_interface = eth1                      #虚拟机私有网络接口
#flat_network_bridge = br0                  #虚拟机桥接网卡
#fixed_range = 192.168.1.240/29             #私有网段
#floating_range = 192.168.1.225/29          #floating ip  可以理解为外网段
#network_size = 8
#flat_network_dhcp_start = 192.168.1.240
#flat_injected = False
#force_dhcp_release = False

for svc in api objectstore compute network volume scheduler cert novncproxy consoleauth;do
	chkconfig openstack-nova-$svc on && service openstack-nova-$svc restart
done

}

nova_show(){
	nova-manage service list
	nova flavor-list
}

nova_create_keypair(){
	rm -rf $KEYPAIR.*
	nova keypair-add $KEYPAIR > $KEYPAIR.priv
	chmod 600 $KEYPAIR.priv
	openstack-config --set /etc/nova/nova.conf DEFAULT libvirt_inject_partition -1
	service openstack-nova-compute restart
}

nova_create_network(){
	### 设置内网IP网段
	nova-manage network create private \
		--multi_host=T \
		--bridge=br0 \
		--bridge_interface=eth0 \
		--fixed_range_v4=192.168.0.80/29 \
		--num_networks=1 \
		--network_size=8
	### 设置外网网段
	nova-manage floating create 192.168.0.80/25
}

swift_init(){
#dd if=/dev/zero of=/var/lib/nova/swift-volumes.img bs=1M seek=1k count=0
#mkfs.xfs -i size=1024 /var/lib/nova/swift-volumes.img
#mount -t xfs -o loop,defaults,noatime,nodiratime,nobarrier,logbufs=8 0 0 to /etc/fstab
#LOOP_DEV=$(losetup -a|awk -F: '/swift-volumes/{split($1,dev,"/")} {print dev[3]}')
LOOP_DEV="sdb2"

rm -rf /etc/rsyncd.conf
rm -rf /etc/swift/swift_ring.sh
rm -rf /etc/swift/account-server.conf
rm -rf /etc/swift/account-server/*.conf
rm -rf /etc/swift/container-server.conf
rm -rf /etc/swift/container-server/*.conf
rm -rf /etc/swift/object-server.conf
rm -rf /etc/swift/object-server/*.conf
rm -rf /etc/swift/*.gz
rm -rf /etc/swift/backups/*
rm -rf /mnt/swift/node*
rm -rf /srv/node*

cat > /etc/swift/swift_ring.sh <<EOF
swift-ring-builder object.builder create 18 3 1
swift-ring-builder container.builder create 18 3 1
swift-ring-builder account.builder create 18 3 1
EOF

cat > /etc/rsyncd.conf <<EOF
# General stuff
uid = swift
gid = swift
log file = /var/log/rsyncd.log
pid file = /var/run/rsyncd.pid
address = 127.0.0.1
EOF

for x in {1..3};do
	i=`printf "%03d" $x`
	mkdir -p /mnt/swift/node$i
	ln -snf /mnt/swift/node$i /srv/
	chown -R swift.swift /mnt/swift
	chown -R swift.swift /srv

cat >> /etc/rsyncd.conf <<EOF

# Account Server replication settings
[account6$i]
max connections = 25
path = /srv/node$i/
read only = false
lock file = /var/lock/account6$i.lock

# Container server replication settings
[container6$i]
max connections = 25
path = /srv/node$i/
read only = false
lock file = /var/lock/container6$i.lock

# Object Server replication settings
[object6$i]
max connections = 25
path = /srv/node$i/
read only = false
lock file = /var/lock/object6$i.lock
############################################
EOF

############################################
cat > /etc/swift/account-server/$i.conf <<EOF
[DEFAULT]
devices = /srv/node$i
mount_check = false
bind_ip = 0.0.0.0
bind_port = 6$i
workers = 3
user = swift
log_facility = LOG_LOCAL1
 
[pipeline:main]
pipeline = account-server

[app:account-server]
use = egg:swift#account
 
[account-replicator]
vm_test_mode = no

[account-auditor]

[account-reaper]
EOF
echo "swift-ring-builder account.builder add z$i-127.0.0.1:6${i}/$LOOP_DEV 100" >> /etc/swift/swift_ring.sh

cat >/etc/swift/container-server/$i.conf <<EOF
[DEFAULT]
devices = /srv/node$i
mount_check = false
bind_ip = 0.0.0.0
bind_port = 6$i
workers = 3
user = swift
log_facility = LOG_LOCAL2

[pipeline:main]
pipeline = container-server

[app:container-server]
use = egg:swift#container

[container-replicator]
vm_test_mode = no

[container-updater]

[container-auditor]

[container-sync]
EOF
echo "swift-ring-builder container.builder add z$i-127.0.0.1:6${i}/$LOOP_DEV 100" >> /etc/swift/swift_ring.sh

cat > /etc/swift/object-server/$i.conf <<EOF
[DEFAULT]
devices = /srv/node$i
mount_check = false
bind_ip = 0.0.0.0
bind_port = 6$i
workers = 3
user = swift
log_facility = LOG_LOCAL3

[pipeline:main]
pipeline = object-server

[app:object-server]
use = egg:swift#object

[object-replicator]
vm_test_mode = no

[object-updater]

[object-auditor]
EOF
echo "swift-ring-builder object.builder add z$i-127.0.0.1:6${i}/$LOOP_DEV 100" >> /etc/swift/swift_ring.sh
cat <<EOF >>/etc/swift/container-server.conf 
[container-sync]
EOF
done
cat >> /etc/swift/swift_ring.sh <<EOF

swift-ring-builder account.builder rebalance
swift-ring-builder container.builder rebalance
swift-ring-builder object.builder rebalance
EOF
############################################
sed -r -i "/disable/s:.*:\tdisable = no:g" /etc/xinetd.d/rsync
mkdir -p /var/log/swift
chown -R swift.root /var/log/swift
cat > /etc/rsyslog.d/10-swift.conf << EOF
local0.*   /var/log/swift/proxy.log
local1.*   /var/log/swift/account.log
local2.*   /var/log/swift/container.log
local3.*   /var/log/swift/object.log
EOF

openstack-config --set /etc/swift/swift.conf swift-hash swift_hash_path_suffix $(od -t x8 -N 8 -A n </dev/random)
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken admin_token $(cat $KS_TOKEN_PRE$ADMIN_USER)
openstack-config --set /etc/swift/proxy-server.conf filter:authtoken auth_token $(cat $KS_TOKEN_PRE$ADMIN_USER)
openstack-config --set /etc/swift/proxy-server.conf filter:keystone operator_roles "Member,admin"
openstack-config --set /etc/swift/proxy-server.conf DEFAULT log_level "DEBUG"
openstack-config --set /etc/swift/proxy-server.conf DEFAULT log_facility "LOG_LOCAL0"
openstack-config --set /etc/swift/proxy-server.conf DEFAULT workers "3"

cd /etc/swift
chmod a+x /etc/swift/swift_ring.sh
./swift_ring.sh
cd -

for svc in account container object proxy;do
	chkconfig openstack-swift-$svc on && service openstack-swift-$svc restart
done
	chkconfig memcached on && service memcached restart
}

swift_start(){
for svc in account container object proxy;do
	chkconfig openstack-swift-$svc on && service openstack-swift-$svc start
done
}

swift_stop(){
for svc in account container object proxy;do
	chkconfig openstack-swift-$svc off && service openstack-swift-$svc stop
done
}

swift_check(){
	cd /etc/swift
	for i in account container object;do
		swift-ring-builder $i.builder
		echo '------------------------------------'
	done
	cd -
}

case $1 in
	env_initalize)
		env_initalize;;
	keys_init)
		keystone_init;;
	keys_adduser)
		keystone_add_user "$@";;
	keys_addtenant)
		keystone_add_tenant "$@";;
	keys_addrole)
		keystone_add_role "$@";;
	keys_addsrv)
		keystone_add_service "$@";;
	keys_addept)
		keystone_add_endpoint "$@";;
	keys_list)
		keystone_list "$@";;
	keys_bind)
		keystone_user_role "$@";;
	gls_init)
		glance_init;;
	gls_add)
		glance_add_image "$@";;
	gls_show)
		glance_show_image "$@";;
	gls_list)
		glance_list_image;;
	nova_init)
		nova_init;;
	nova_check)
		nova_show;;
	nova_network)
		nova_network;;
	nova_addkey)
		nova_create_keypair;;
	nova_addnet)
		nova_create_network;;
        swift_init)
                swift_init;;
	swift_start)
		swift_start;;
	swift_stop)
		swift_stop;;
        swift_check)
                swift_check;;
	*)
		echo -e "${RED_COL}$SCRIPT ${YELLOW_COL}env_initalize"
		echo -e "${RED_COL}$SCRIPT ${GREEN_COL}keys_init|keys_adduser|keys_addtenant|keys_addrole|keys_addsrv|keys_addept|keys_bind|keys_list"
		echo -e "${RED_COL}$SCRIPT ${GREEN_COL}gls_init|gls_add|gls_show|gls_list"
		echo -e "${RED_COL}$SCRIPT ${GREEN_COL}nova_init|nova_addkey|nova_addnet|nova_check"
                echo -e "${RED_COL}$SCRIPT ${GREEN_COL}swift_init|swift_start|swift_stop|swift_check"
		echo -en ${NORMAL_COL}
esac

