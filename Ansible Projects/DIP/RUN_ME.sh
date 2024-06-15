#!/bin/bash
#THIS IS THE DIP (DEPLOYABLE INFRASTRUCTURE PLATFORM); IF YOU HAVE ANY QUESTIONS DEFER TO...

#Puts a wait in the script
debugger() {
  echo "--------------------"
  echo "Press any key to continue..."
  read -rsn1
}

#=============================================================================================================================
#Menu functions
#-----------------------------------------------

#Setup passwordless SSH
passwordless_laptoplap2prox() {
  clear
  echo "============================================="
  echo "Configuring LAPTOP CONTROL NODE to PROXMOX NODE(s) passwordless authentication..."
  echo "============================================="
  rm -rf /root/.ssh
  ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N "" #on LAPTOP CONTROL NODE
  for i in ${prox_ips[@]}; do
    sshpass -p $USERPASS ssh -o StrictHostKeyChecking=no root@$i 'rm -rf /root/.ssh'
    sshpass -p $USERPASS ssh-copy-id -i /root/.ssh/id_rsa root@$i #on PROXMOX NODE(s) for LAPTOP CONTROL NODE
    echo "============================================="
    ssh root@$i 'echo "Hello" 1>/dev/null' && echo "Passwordless config for $i from LAPTOP CONTROL NODE successful"
    echo "============================================="
    echo "^ Should say Passwordless config for $i from LAPTOP CONTROL NODE successful ^"
  done
}
passwordless_proxlap2prox() {
  clear
  echo "============================================="
  echo "Configuring PROXMOX CONTROL NODE to PROXMOX WORKER(s) passwordless authentication..."
  echo "============================================="
  rm -rf /root/.ssh
  ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N "" #on PROXMOX CONTROL NODE
  touch /root/.ssh/known_hosts
  cat /root/.ssh/id_rsa > /root/.ssh/known_hosts
  for i in ${prox_ips[@]}; do
    sshpass -p $USERPASS ssh -o StrictHostKeyChecking=no root@$i 'rm -rf /root/.ssh'
    sshpass -p $USERPASS ssh-copy-id -i /root/.ssh/id_rsa root@$i #on PROXMOX WORKERS(s) for PROXMOX CONTROL NODE
    echo "============================================="
    ssh root@$i 'echo "Hello" 1>/dev/null' && echo "Passwordless config for $i from PROXMOX CONTROL NODE successful"
    echo "============================================="
    echo "^ Should say Passwordless config for $i from PROXMOX CONTROL NODE successful ^"
  done
}
passwordless_laptopproxW2proxM() {
  clear
  echo "============================================="
  echo "Configuring PROXMOX WORKER(s) to PROXMOX MASTER passwordless authentication..."
  echo "============================================="
  for ((i=1; i<"${#prox_ips[@]}"; i++)); do
    ssh root@${prox_ips[$i]} 'ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N ""'
    ssh root@${prox_ips[$i]} "sshpass -p $USERPASS ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa root@${prox_ips[0]}"
    echo "============================================="
    ssh root@${prox_ips[$i]} "ssh root@${prox_ips[0]} 'echo "Hello" 1>/dev/null'" && echo "Passwordless config for ${prox_ips[$i]} to PROXMOX MASTER successful"
    echo "============================================="
    echo "^ Should say Passwordless config for ${prox_ips[$i]} to PROXMOX MASTER successful ^"
  done
}
passwordless_proxproxW2proxM() {
  clear
  echo "============================================="
  echo "Configuring PROXMOX WORKER(s) to PROXMOX CONTROL NODE passwordless authentication..."
  echo "============================================="
  for ((i=0; i<"${#prox_ips[@]}"; i++)); do
    ssh root@${prox_ips[$i]} 'ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N ""'
    ssh root@${prox_ips[$i]} "sshpass -p $USERPASS ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/id_rsa root@$prox_control"
    echo "============================================="
    ssh root@${prox_ips[$i]} "ssh root@$prox_control 'echo "Hello" 1>/dev/null'" && echo "Passwordless config for ${prox_ips[$i]} to PROXMOX CONTROL NODE successful"
    echo "============================================="
    echo "^ Should say Passwordless config for ${prox_ips[$i]} to PROXMOX CONTROL NODE successful ^"
  done
}

#=============================================================================================================================
#Menu functions
#-----------------------------------------------

#Check for Dialog and Ansible
while [[ -z $(which dialog 2>/dev/null) ]] || [[ -z $(which ansible-vault 2>/dev/null) ]]; do
  clear
  echo "--------------------"
  echo "Installing Dialog and Ansible..."
  apt=$(which apt 2>/dev/null)
  dnf=$(which dnf 2>/dev/null)
  if [[ -n $apt ]]; then
    dpkg --force-depends -i ./packages/debs/dialog/*.deb #dpkg -i ./packages/debs/*/*.deb
    dpkg --force-depends -i ./packages/debs/ansible/*.deb
  elif [[ -n $dnf ]]; then
    dnf -y install --disablerepo=* ./packages/rpms/dialog/*.rpm
    dnf -y install --disablerepo=* ./packages/rpms/ansible/*.rpm
  else
    clear
    echo "--------------------"
    echo "You do not have apt or dnf as a package manager, so I can not extrapolate how to install the needed .deb or .rpm files."
    echo "They are needed to move on with a remote install, or you can re-run and install on the Proxmox."
    exit
  fi
done

#Checks some things as prerequisites for deploying DIP
status_check() {
  pvedaemon=$(ps -x | awk '{print $5}' | egrep ^pvedaemon) #Determines if script host is Proxmox
  internet=$(ping -c 1 8.8.8.8 2>/dev/null | grep 'bytes from') & #Tests connection to 8.8.8.8
  dns=$(ping -c 1 google.com 2>/dev/null | grep 'bytes from') & #Tests connection to google.com
  if [[ -n $pvedaemon ]]; then
    nic=$(ip a | grep "master vmbr0") #Grabs NIC of script host
    ipaddr=$(ip a | grep "scope global vmbr0" | awk '{print $2}') #Grabs IP of script host
  else
    nic=$(ip a | grep "state UP") #Grabs NIC of script host
    ipaddr=$(ip a | grep "scope global" | awk '{print $2}') #Grabs IP of script host
  fi
}

#Define the dialog exit status codes
: ${DIALOG_OK=0}
: ${DIALOG_CANCEL=1}
: ${DIALOG_HELP=2}
: ${DIALOG_EXTRA=3}
: ${DIALOG_ITEM_HELP=4}
: ${DIALOG_ESC=255}

#Create some temporary files and make sure they go away when we are done
tmp_file=$(tempfile 2>/dev/null) || tmp_file=/tmp/test$$
trap "rm -f $tmp_file" 0 1 2 5 15

#Test to see that it is the correct password and push back to unseal function if not
validate_vault() {
  if [[ -n $VAULT_PASS ]]; then
    echo "${VAULT_PASS}" | ansible-vault view ./ansible/passwords.yml --vault-pass-file=/bin/cat 2>&1 > /dev/null
    if [[ $? -eq 1 ]]; then
      VAULT_SUCCESS=FALSE
      echo "PASSWORD INVALID! Press enter to continue..."
      unset $VAULT_PASS
      read
    else
      VAULT_SUCCESS=TRUE
    fi
  else
    echo "Enter a password! Press enter to continue..."
    unset $VAULT_PASS
    read
  fi
}

#Have user input a password to un-encrypt the vault; Password will be agreed upon beforehand
unseal_vault() {
  VAULT_PASS=`dialog --backtitle "DIP (Deployable Infrastructure Platform)" \
      --title "Unseal Vault" \
      --insecure  "$@" \
      --passwordbox "Please enter the password to the Ansible Vault:" 10 65 2>&1 > /dev/tty`
  
  #Set return_value variable to previous commands return code
  return_value=$?
  clear
  #Handle menu progression
  case $return_value in
    $DIALOG_OK)
      validate_vault;;
    $DIALOG_CANCEL)
      echo "Goodbye :)"
      exit;;
    $DIALOG_HELP)
      echo "Help pressed.";;
    $DIALOG_EXTRA)
      echo "Extra button pressed.";;
    $DIALOG_ITEM_HELP)
      echo "Item-help button pressed.";;
    $DIALOG_ESC)
      if test -s $tmp_file ; then
        cat $tmp_file
      else
        echo "ESC pressed."
      fi
      echo "Goodbye :)"
      exit;;
  esac
}

#=============================================================================================================================
#Main functions
#-----------------------------------------------
infrastructure_action() {
  PROX_SUCCESS=FALSE
  while [[ $PROX_SUCCESS == FALSE ]]; do
    PROX_PASS1=`dialog --backtitle "DIP (Deployable Infrastructure Platform)" \
        --title "Proxmox Password" \
        --insecure  "$@" \
        --passwordbox "Please enter the password you gave root on Proxmox:" 10 65 2>&1 > /dev/tty`
    

    #Set return_value variable to previous commands return code
    return_value=$?
    clear
    #Handle menu progression
    case $return_value in
      $DIALOG_OK)
        if [[ -n $PROX_PASS1 ]]; then
          PROX_PASS2=`dialog --backtitle "DIP (Deployable Infrastructure Platform)" \
              --title "Proxmox Password" \
              --insecure  "$@" \
              --passwordbox "Please confirm the password:" 10 65 2>&1 > /dev/tty`
          if [[ $PROX_PASS1 == $PROX_PASS2 ]]; then
            #Off to the races!
            PROX_SUCCESS=TRUE
            USERPASS=$PROX_PASS2
            unset $PROX_PASS1
            unset $PROX_PASS2
            if [[ -n $pvedaemon ]]; then
              #The following is only run if the script host is Proxmox
              prox_ips=($(for i in {132..140}; do (ping -c 1 10.1.1.$i | grep 'bytes from' &); done | grep -Eo "10\.1\.1\.\w*"))
              if [[ -z $dns ]]; then
                echo "Installing Ansible and its dependencies needed for this exercise..."
                dpkg --force-depends -i ./packages/debs/ansible/*.deb #dpkg -i ./packages/debs/*/*.deb
                dpkg --force-depends -i ./packages/debs/openvswitch-proxmoxer-sshpass/*.deb
              else
                echo "Installing Ansible and its dependencies needed for this exercise..."
                apt -y update > /dev/null 2>&1
                apt -y install ansible sshpass openvswitch-common openvswitch-switch python3-proxmoxer > /dev/null 2>&1
              fi
              prox_control=$(ip a | grep vmbr0 | grep inet | awk '{print $2}' | awk -F/ '{print $1}')
              if [[ -n "${prox_ips[@]}" ]]; then
                passwordless_proxlap2prox
                for i in ${prox_ips[@]}; do
                  ssh root@$i 'mkdir /root/ansible'
                  ssh root@$i 'mkdir /root/openvswitch-proxmoxer-sshpass'
                  scp -r ./packages/debs/ansible root@$i:/root
                  scp -r ./packages/debs/openvswitch-proxmoxer-sshpass root@$i:/root
                  ssh root@$i 'dpkg --force-depends -i ./ansible/*.deb'
                  ssh root@$i 'dpkg --force-depends -i ./openvswitch-proxmoxer-sshpass/*.deb' #dpkg -i *.deb
                done
                passwordless_proxproxW2proxM
                clear
                echo "============================================="
                echo "Creating Proxmox cluster..."
                echo "============================================="
                pvecm create PROXCLUSTER
                echo "============================================="
                echo "Waiting for cluster to fully initialize..."
                sleep 60
                clear
                for ((i=0; i<"${#prox_ips[@]}"; i++)); do
                  echo "============================================="
                  echo "Trying to add ${prox_ips[$i]} to the cluster..."
                  echo "============================================="
                  ssh root@${prox_ips[$i]} "printf '$USERPASS\nyes\n' | pvecm add $prox_control -force true" #backwards issue FIXED
                done
                clear
                echo "============================================="
                echo "You have created a Proxmox cluster..."
                pvecm status
                echo "============================================="
                IFS=$'\n';c_ints=($(ssh root@${prox_ips[0]} 'ip a | grep -v "master vmbr0" | grep "state"' | awk '{print $2}' | awk -F: '{print $1}' | grep -v 'lo' | grep -v 'vmbr' | grep -v 'ovs-system' | grep -v 'tap' | grep -v 'fw'));IFS=' '
              else
                clear
                echo "============================================="
                echo "No Proxmox cluster needed, you only have one node."
                echo "============================================="
                rm -rf /root/.ssh
                ssh-keygen -t rsa -b 2048 -f /root/.ssh/id_rsa -N "" #on PROXMOX CONTROL NODE
                touch /root/.ssh/known_hosts
                cat /root/.ssh/id_rsa > /root/.ssh/known_hosts
                IFS=$'\n';ints=($(ip a | grep -v 'master vmbr0' | grep 'state' | awk '{print $2}' | awk -F: '{print $1}' | grep -v 'lo' | grep -v 'vmbr' | grep -v 'ovs-system' | grep -v 'tap' | grep -v 'fw'));IFS=' '
              fi
              eth_ints=()
              for i in "${ints[@]}"; do
                non_fibre=$(ethtool $i | grep 'Supported ports:' | awk '{print $4}')
                if [[ "$non_fibre" =~ "TP" ]]; then
                  eth_ints=("${eth_ints[@]}" $i)
                fi
              done
              inv_check=$(cat ./ansible/inventory.cfg)
              if [[ -z "$inv_check" ]]; then
                printf "%s\n" '[all:vars]' 'ansible_user=root' 'ansible_password='$USERPASS 'p_vmbr_ints='"${eth_ints[*]}" 'a_vmbr1_int='${eth_ints[0]} 'c_vmbr1_int='${c_ints[0]}  '[proxmox]' $HOSTNAME ${prox_ips[@]} '[prox_master]' $HOSTNAME  '[prox_workers]' ${prox_ips[@]} >> ./ansible/inventory.cfg
              else
                echo '' > ./ansible/inventory.cfg
                printf "%s\n" '[all:vars]' 'ansible_user=root' 'ansible_password='$USERPASS 'p_vmbr_ints='"${eth_ints[*]}" 'a_vmbr1_int='${eth_ints[0]} 'c_vmbr1_int='${c_ints[0]}  '[proxmox]' $HOSTNAME ${prox_ips[@]} '[prox_master]' $HOSTNAME  '[prox_workers]' ${prox_ips[@]} >> ./ansible/inventory.cfg
              fi
              unset $USERPASS
              echo "============================================="
              echo "Waiting 30 seconds to let Proxmox settle itself..."
              echo "============================================="
              echo "Check your hardware NICs to find what port(s) ingestion will be setup on, blinking for 30 seconds..."
              echo "============================================="
              if [[ "$cluster_platform" =~ [pP] ]]; then
                for i in ${eth_ints[@]}; do
                  ssh root@${prox_ips[0]} "ethtool -p $i 5"
                done
              elif [[ "$cluster_platform" =~ [aA] ]]; then
                ssh root@${prox_ips[0]} "ethtool -p ${eth_ints[0]} 30"
              elif [[ "$cluster_platform" =~ [cC] ]]; then
                ssh root@${prox_ips[1]} "ethtool -p ${c_ints[0]} 30"
              else
                echo "============================================="
                echo "Cannot blink, not able to extrapolate ingestion..."
                echo "============================================="
                sleep 30
              fi
              clear
              echo "============================================="
              echo "We are going to start the Ansible now."
              echo "============================================="
              ansible_check='--check' #This is set so that we can test...
              cd ./ansible
              ansible-playbook $ansible_check playbooks/01_configure_proxmox.yml
              ansible-playbook $ansible_check playbooks/11_deploy_opnsense.yml
              ansible-playbook $ansible_check playbooks/12_deploy_c2.yml
              if [[ "$cluster_platform" =~ [pP] ]]; then
                ansible-playbook $ansible_check playbooks/13_deploy_securityonion.yml
              elif [[ "$cluster_platform" =~ [aA] ]]; then
                ansible-playbook $ansible_check playbooks/132_deploy_securityonion.yml
              elif [[ "$cluster_platform" =~ [cC] ]]; then
                ansible-playbook $ansible_check playbooks/133_deploy_securityonion.yml
              else
                echo "============================================="
                echo "I have not deployed Security Onion as I do not know what kind of cluster platform we are working with."
                echo "============================================="
              fi
            else
              #The following is only run if the script host is not Proxmox
              prox_ips=($(for i in {131..140}; do (ping -c 1 10.1.1.$i | grep 'bytes from' &); done | grep -Eo "10\.1\.1\.\w*"))
              if [[ -z $dns ]]; then
                if [[ -n $apt ]]; then
                  echo "I see you are using a Debian based distribution of Linux..."
                  echo "Installing Ansible and its dependencies needed for this exercise..."
                  dpkg --force-depends -i ./packages/debs/ansible/*.deb #dpkg -i ./packages/debs/*/*.deb
                  dpkg --force-depends -i ./packages/debs/openvswitch-proxmoxer-sshpass/*.deb
                elif [[ -n $dnf ]]; then
                  echo "I see you are using a Red-Hat based distribution of Linux..."
                  echo "Installing Ansible and its dependencies needed for this exercise..."
                  dnf -y install --disablerepo=* ./packages/rpms/*/*.rpm
                else
                  echo "You do not have apt or dnf as a package manager, so I can not extrapolate how to install the .deb or .rpm files for Ansible."
                  echo "They are needed to move on with external control install, or you can re-run and install on the Proxmox."
                  exit
                fi
              else
                if [[ -n $apt ]]; then
                  echo "I see you are using a Debian based distribution of Linux..."
                  echo "Installing Ansible and its dependencies needed for this exercise..."
                  apt -y update > /dev/null 2>&1
                  apt -y install ansible sshpass openvswitch-common openvswitch-switch python3-proxmoxer > /dev/null 2>&1
                elif [[ -n $dnf ]]; then
                  echo "I see you are using a Red-Hat based distribution of Linux..."
                  echo "Installing Ansible and its dependencies needed for this exercise..."
                  dnf -y update > /dev/null 2>&1
                  dnf -y install ansible sshpass openvswitch-common openvswitch-switch python3-proxmoxer > /dev/null 2>&1
                else
                  echo "You do not have apt or dnf as a package manager, so I can not extrapolate how to install the .deb or .rpm files for Ansible."
                  echo "They are needed to move on with external control install, or you can re-run and install on the Proxmox."
                  exit
                fi
              fi
              passwordless_laptoplap2prox
              for i in ${prox_ips[@]}; do
                ssh root@$i 'mkdir /root/ansible'
                ssh root@$i 'mkdir /root/openvswitch-proxmoxer-sshpass'
                scp -r ./packages/debs/ansible root@$i:/root
                scp -r ./packages/debs/openvswitch-proxmoxer-sshpass root@$i:/root
                ssh root@$i 'dpkg --force-depends -i ./ansible/*.deb'
                ssh root@$i 'dpkg --force-depends -i ./openvswitch-proxmoxer-sshpass/*.deb' #dpkg -i *.deb
              done
              if [[ "${#prox_ips[@]}" -gt 1 ]]; then
                passwordless_laptopproxW2proxM
                clear
                echo "============================================="
                echo "Creating Proxmox cluster..."
                echo "============================================="
                ssh root@${prox_ips[0]} 'pvecm create PROXCLUSTER'
                echo "============================================="
                echo "Waiting for cluster to fully initialize..."
                sleep 60
                clear
                for ((i=1; i<"${#prox_ips[@]}"; i++)); do
                  echo "============================================="
                  echo "Trying to add ${prox_ips[$i]} to the cluster..."
                  echo "============================================="
                  ssh root@${prox_ips[$i]} "printf '$USERPASS\nyes\n' | pvecm add ${prox_ips[0]} -force true" #backwards issue FIXED
                done
                clear
                echo "============================================="
                echo "You have created a Proxmox cluster..."
                ssh root@${prox_ips[0]} 'pvecm status'
                echo "============================================="
                IFS=$'\n';c_ints=($(ssh root@${prox_ips[1]} 'ip a | grep -v "master vmbr0" | grep "state"' | awk '{print $2}' | awk -F: '{print $1}' | grep -v 'lo' | grep -v 'vmbr' | grep -v 'ovs-system' | grep -v 'tap' | grep -v 'fw'));IFS=' '
              else
                clear
                echo "============================================="
                echo "No Proxmox cluster needed, you only have one node."
                echo "============================================="
                IFS=$'\n';ints=($(ssh root@${prox_ips[0]} 'ip a | grep -v "master vmbr0" | grep "state"' | awk '{print $2}' | awk -F: '{print $1}' | grep -v 'lo' | grep -v 'vmbr' | grep -v 'ovs-system' | grep -v 'tap' | grep -v 'fw'));IFS=' '
              fi
              eth_ints=()
              for i in "${ints[@]}"; do
                non_fibre=$(ssh root@${prox_ips[0]} "ethtool $i | grep 'Supported ports:'" | awk '{print $4}')
                if [[ "$non_fibre" =~ "TP" ]]; then
                  eth_ints=("${eth_ints[@]}" $i)
                fi
              done
              inv_check=$(cat ./ansible/inventory.cfg)
              if [[ -z "$inv_check" ]]; then
                printf "%s\n" '[all:vars]' 'ansible_user=root' 'ansible_password='$USERPASS 'p_vmbr_ints='"${eth_ints[*]}" 'a_vmbr1_int='${eth_ints[0]} 'c_vmbr1_int='${c_ints[0]}  '[proxmox]' ${prox_ips[@]}  '[prox_master]' ${prox_ips[0]}  '[prox_workers]' ${prox_ips[@]:1} >> ./ansible/inventory.cfg
              else
                echo '' > ./ansible/inventory.cfg
                printf "%s\n" '[all:vars]' 'ansible_user=root' 'ansible_password='$USERPASS 'p_vmbr_ints='"${eth_ints[*]}" 'a_vmbr1_int='${eth_ints[0]} 'c_vmbr1_int='${c_ints[0]}  '[proxmox]' ${prox_ips[@]}  '[prox_master]' ${prox_ips[0]}  '[prox_workers]' ${prox_ips[@]:1} >> ./ansible/inventory.cfg
              fi
              unset $USERPASS
              echo "============================================="
              echo "Waiting 30 seconds to let Proxmox settle itself..."
              echo "============================================="
              echo "Check your hardware NICs to find what port(s) ingestion will be setup on, blinking for 30 seconds..."
              echo "============================================="
              if [[ "$cluster_platform" =~ [pP] ]]; then
                for i in ${eth_ints[@]}; do
                  ssh root@${prox_ips[0]} "ethtool -p $i 5"
                done
              elif [[ "$cluster_platform" =~ [aA] ]]; then
                ssh root@${prox_ips[0]} "ethtool -p ${eth_ints[0]} 30"
              elif [[ "$cluster_platform" =~ [cC] ]]; then
                ssh root@${prox_ips[1]} "ethtool -p ${c_ints[0]} 30"
              else
                echo "============================================="
                echo "Cannot blink, not able to extrapolate ingestion..."
                echo "============================================="
                sleep 30
              fi
              clear
              echo "============================================="
              echo "We are going to start the Ansible now."
              echo "============================================="
              ansible_check='--check' #This is set so that we can test...
              cd ./ansible
              ansible-playbook $ansible_check playbooks/01_configure_proxmox.yml
              ansible-playbook $ansible_check playbooks/11_deploy_opnsense.yml
              ansible-playbook $ansible_check playbooks/12_deploy_c2.yml
              if [[ "$cluster_platform" =~ [pP] ]]; then
                ansible-playbook $ansible_check playbooks/13_deploy_securityonion.yml
              elif [[ "$cluster_platform" =~ [aA] ]]; then
                ansible-playbook $ansible_check playbooks/132_deploy_securityonion.yml
              elif [[ "$cluster_platform" =~ [cC] ]]; then
                ansible-playbook $ansible_check playbooks/133_deploy_securityonion.yml
              else
                echo "============================================="
                echo "I have not deployed Security Onion as I do not know what kind of cluster platform we are working with."
                echo "============================================="
              fi
            fi
            cd ..
            echo '' > ./ansible/inventory.cfg
            echo "/////////////////////////////////////////////"
            debugger
            #.................................................
          else
            PROX_SUCCESS=FALSE
            echo "PASSWORD DOES NOT MATCH! Press enter to continue..."
            unset $PROX_PASS1
            unset $PROX_PASS2
            read
          fi
        else
          echo "ENTER A PASSWORD! Press enter to continue..."
          unset $PROX_PASS1
          unset $PROX_PASS2
          read
        fi;;
      $DIALOG_CANCEL)
        echo "Cancel pressed."
        break;;
      $DIALOG_HELP)
        echo "Help pressed.";;
      $DIALOG_EXTRA)
        echo "Extra button pressed.";;
      $DIALOG_ITEM_HELP)
        echo "Item-help button pressed.";;
      $DIALOG_ESC)
        if test -s $tmp_file ; then
          cat $tmp_file
        else
          echo "ESC pressed."
        fi
        break;;
    esac
  done
}

#=============================================================================================================================
#=============================================================================================================================
#=============================================================================================================================
#Menus
#-----------------------------------------------

#Infrastructure menu for DIP
infra_menu() {
  #See status check function
  status_check

  dialog --colors \
      --backtitle "DIP (Deployable Infrastructure Platform)" \
      --title "Infrastructure Menu" "$@" \
      --checklist "Deploy some Infrastructure! \n\
  Select the infrastructure you would like to deploy. \n\n\
  PVE$(if [ -n "$pvedaemon" ]; then echo -e "\t- \Z2YES\Zn"; else echo -e "\t- \Z1NO\Zn"; fi) \n\
  INTERNET$(if [ -n "$internet" ]; then echo -e "\t- \Z2SUCCESS\Zn"; else echo -e "\t- \Z1FAILURE\Zn"; fi) \n\
  DNS$(if [ -n "$dns" ]; then echo -e "\t- \Z2SUCCESS\Zn"; else echo -e "\t- \Z1FAILURE\Zn"; fi) \n\
  $(echo $ipaddr) \n\n\
  Which of the following would you like to setup?" 22 65 5 \
          "Networking" "Router and vSwitches." on \
          "Nextcloud" "C2 - Local SAAS Storage." off \
          "Mattermost" "C2 - Team Communication." off \
          "Redmine" "C2 - Management/Issue Tracking." off \
          "Security Onion" "Distributed Deployment." off 2> $tmp_file

  #Set return_value variable to previous commands return code
  return_value=$?

  clear
  #Handle menu progression
  case $return_value in
    $DIALOG_OK)
      infrastructure_action;;
    $DIALOG_CANCEL)
      echo "Cancel pressed.";;
    $DIALOG_HELP)
      echo "Help pressed.";;
    $DIALOG_EXTRA)
      echo "Extra button pressed.";;
    $DIALOG_ITEM_HELP)
      echo "Item-help button pressed.";;
    $DIALOG_ESC)
      if test -s $tmp_file ; then
        cat $tmp_file
      else
        echo "ESC pressed."
      fi
      ;;
  esac
}

#=============================================================================================================================
#=============================================================================================================================

#Error correction menu for DIP


#=============================================================================================================================
#=============================================================================================================================

#Teardown menu for DIP


#===========================================================================================================================================================

#======================================================================================================================================

#======================================================================================================================================

#======================================================================================================================================
#Main flow
#-----------------------------------------------

#Set vault success for default; loop vault is unsealed with correct password
VAULT_SUCCESS=FALSE
while [[ $VAULT_SUCCESS == FALSE ]]; do
unseal_vault
done

#Main menu for DIP
MAIN_MENU=TRUE
while [[ $MAIN_MENU == TRUE ]]; do
  dialog --colors \
      --backtitle "DIP (Deployable Infrastructure Platform)" \
      --title "Main Menu" "$@" \
      --menu "Welcome to the DIP! \n\
  This is a program made to ease setup of \n\
  boutique DCO infrastructure for risky analysis. \n\n\
  What would you like to do?" 15 65 5 \
          "Infrastructure" "Choose what to deploy." \
          "View Vault" "See all your passwords." \
          "Error Correction" "Attempt error correction to deploy." \
          "Teardown" "Teardown and start over." 2> $tmp_file

  #Set return_value variable to previous commands return code
  return_value=$?

  clear
  #Handle menu progression  
  case $return_value in
    $DIALOG_OK)
      if [[ "$(cat $tmp_file)" =~ "Infrastructure" ]]; then
        infra_menu
      elif [[ "$(cat $tmp_file)" =~ "View Vault" ]]; then
        echo "${VAULT_PASS}" | ansible-vault view ./ansible/passwords.yml --vault-pass-file=/bin/cat
        debugger
      elif [[ "$(cat $tmp_file)" =~ "Error Correction" ]]; then
        echo "Performing error correction..."
        debugger
      elif [[ "$(cat $tmp_file)" =~ "Teardown" ]]; then
        echo "Tearing everything down..."
        debugger
      fi;;
    $DIALOG_CANCEL)
      echo "Cancel pressed."
      MAIN_MENU=FALSE;;
    $DIALOG_HELP)
      echo "Help pressed.";;
    $DIALOG_EXTRA)
      echo "Extra button pressed.";;
    $DIALOG_ITEM_HELP)
      echo "Item-help button pressed.";;
    $DIALOG_ESC)
      if test -s $tmp_file ; then
        cat $tmp_file
      else
        echo "ESC pressed."
        MAIN_MENU=FALSE
      fi
      ;;
  esac
done








unset $VAULT_PASS
clear
echo "EOS"
echo "Goodbye :)"