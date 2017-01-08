#!/bin/bash

usage()
{
	echo -e "expected usage:
$0 [-d|--debug] [-i|--inactive]
	[-q|--quota MB]		repo {ls|add|disable|rem} REPO
	[-s|--ssh-key FILE]	user {ls|add|disable|rem} USER
	[-r|--read-only]	auth {ls|add|rem} USER REPO

NOTE: quotas not yet implemented.
NOTE: script should be run with root privileges.
NOTE: space characters in repo names will be replaced with underscores." >&2
}


# static assumptions
REPO_BASE="/usr/src/git"	# active repos go here
ARCH_BASE="/usr/src/archive"	# disabled repos go here


# get arguments
QUOTA_=
KEY_=
READ_=
DEBUG_=
INACTIVE_=
while [[ "$1" \
	&& "$1" != "repo" \
	&& "$1" != "user" \
	&& "$1" != "auth" ]]
do
	case $1 in
	-d|--debug)
		DEBUG_=1
		shift
		;;
	-i|--inactive)
		INACTIVE_=1
		shift
		;;
	-q|--quota)
		DEBUG_PRN_="got quota of $2"
		QUOTA_="$2"
		shift; shift
		;;
	-s|--ssh-key)
		DEBUG_PRN_="got key $2"
		KEY_="$2"
		shift; shift
		;;
	-r|--read-only)
		DEBUG_PRN_="read-only"
		READ_=1
		shift
		;;
	*)
		usage
		exit 1
		;;
	esac
	# optional argument debug print
	if [[ $DEBUG_ ]]; then
		echo "$DEBUG_PRN_"
	fi
done


#	check_platform()
#
# Verify that all required platform components are copacetic
check_platform()
{
	# can only run on a Linux ATM
	if ! uname -s | grep "Linux" >/dev/null; then
		echo "$(uname -s) is not a Linux?" >&2
		exit 1
	fi

	# must be root
	if [[ $(whoami) != "root" ]]; then
		echo "must run as root" >&2
		exit 1
	fi

	# SSH should ideally NOT allow password logins
	if grep -E "^[^#]+asswordAuthentication\s+yes" /etc/ssh/sshd_config >/dev/null; then
		echo "WARNING: your ssh server allows password logins. Please consider disabling this." >&2
	fi
	#TODO verify REPO_BASE exists on an FS mounted with quotas
}


#	repo()
#
#		$1	:	{ls|add|archive|exhume}
#		$2	:	REPO
#
# TODO implement quotas
repo()
{
	# all invocations reqire a command
	if [[ ! "$1" ]]; then
		usage
		exit 1
	fi

	# 	list
	# Show either active or inactive repos
	if [[ "$1" == "ls" || "$1" == "list" ]]; then
		if [[ ! $INACTIVE_ ]]; then
			ls -1 "$REPO_BASE"
			return $?
		else
			ls -1 --ignore=".mounts" "$ARCH_BASE"
			return $?
		fi
	fi

	# all other invocations besides "list" require a repo name
	if [[ ! "$2" ]]; then
		usage
		exit 1
	fi
	# remove all spaces from repo
	$2=$(echo "$2" | sed 's/ /_/g')

	# force existence of REPO and ARCH
	mkdir -p "$REPO_BASE" "$ARCH_BASE"
		poop=$?; if (( $poop )); then exit $poop; fi
	chown root: "$REPO_BASE" "$ARCH_BASE"
		poop=$?; if (( $poop )); then exit $poop; fi
	chmod u=rwx,go-rwx "$REPO_BASE" "$ARCH_BASE"
		poop=$?; if (( $poop )); then exit $poop; fi

	case $1 in
		#	add
		# add a new repository;
		# reactivate a disabled repo;
		# validate/force settings on an existing active repo.
		add)
			# repo dir doesn't currently exist
			if [[ ! -d "$REPO_BASE/$2" ]]; then

				# if it exists but is disabled, move it back
				if [[ -d "$ARCH_BASE/$2" ]]; then
					mv "$ARCH_BASE/$2" "$REPO_BASE/$2"
					poop=$?; if (( $poop )); then exit $poop; fi
					# restore fstab entries for repo
					cat "$ARCH_BASE/$2.mounts" >>/etc/fstab
					rm -f "$ARCH_BASE/$2.mounts"
					sort -o /etc/fstab /etc/fstab

				# no? create it
				else
					mkdir "$REPO_BASE/$2"
					poop=$?; if (( $poop )); then exit $poop; fi
					pushd "$REPO_BASE/$2"
					git init --bare
					poop=$?; if (( $poop )); then popd; rm -rf "$REPO_BASE/$2"; exit $poop; fi
				fi
			fi

			# make sure repo-specific group exists
			if ! getent group | grep "git_$2" >/dev/null; then
				addgroup "git_$2"
					poop=$?; if (( $poop )); then exit $poop; fi
			fi

			# force ownership and permissions on repo dir
			chown -R nobody:"git_$2" "$REPO_BASE/$2"
				poop=$?; if (( $poop )); then exit $poop; fi
			chmod -R u=rwX,g=rwXs,o=rX,o-w "$REPO_BASE/$2" # notice group sticky bit
				poop=$?; if (( $poop )); then exit $poop; fi
			# This is to allow git to write temporary account stuff
			#+	when a read-only user pulls
			# TODO any way around this? (if so, change fstab mount stanza to say "r"
			chmod o+w "$REPO_BASE/$2"
				poop=$?; if (( $poop )); then exit $poop; fi

			# refresh mounts
			mount -a
			;;

		#	disable
		# Archive an existing repo; disable access by users but save
		#+	their ~/[repo] mountpoints intact for later restoration.
		# NOTE that some mountpoints may have been DISABLED, we need to preserve this.
		disable)
			# verify repo exists in the first place
			if [[ ! -d "$REPO_BASE/$2" ]]; then
				echo "Repo '$2' doesn't exist. Cannot archive" >&2
				exit 1
			fi

			# verify no archived project by the same name
			if [[ -d "$ARCH_BASE/$2" ]]; then
				echo "Archived repo '$2' already exists." >&2
				exit 1
			fi

			# preserve mount entries from fstab
			sed -rn '\|'"$REPO_BASE/$2"'| p' /etc/fstab >"$ARCH_BASE/$2.mounts"
			# recurse: purge mounts
			repo purge_mounts $2

			# move repo to archive
			mv "$REPO_BASE/$2" "$ARCH_BASE/$2"
				poop=$?; if (( $poop )); then exit $poop; fi
			;;

		#	rem
		# Remove a repo entirely; whether archived or active
		rem|del|delete)
			# purge mounts
			repo purge_mounts $2
			# remove all mount dirs
			find /home -type d -name "$2" -exec rm -rf '{}' \;

			#remove group
			groupdel "git_$2"
				poop=$?; if (( $poop )); then exit $poop; fi

			# remove repo and/or archive dir, archived mounts list
			rm -rf "$REPO_BASE/$2" "$ARCH_BASE/$2*"
			;;

		#	purge_mounts
		# unmount any bind-mounts pointing at repo, remove them from fstab
		purge_mounts)
			# unmount all instances of repo
			find /home -type d -name "$2" -exec umount -v '{}' \;
			# delete them
			sed -i"" -r '\|'"$REPO_BASE/$2"'| d' fstab
			;;

		*)
			echo "Unknown command '$1'" >&2
			usage
			exit 1
			;;
	esac
}


#	user()
#		$1	:	{ls|add|disable|rem}
#		$2	:	USER
user()
{
	# all calls require command
	if [[ ! "$1" ]]; then
		usage
		exit 1
	fi

	# 	list
	# Show either active or inactive users
	if [[ "$1" == "ls" || "$1" == "list" ]]; then
		# disabled users have '.ssh/disabled'
		if [[ $INACTIVE_ ]]; then
			COND_=".ssh/disabled"
		# active ones have 'authorized_keys' instead
		else
			COND_=".ssh/authorized_keys"
		fi
		# only go through "git-shell" users
		for u in $(getent passwd | grep git-shell | cut -d ':' -f 1); do
			if [[ -e "/home/$u/$COND_" ]]; then
				echo $u
			fi
		done
		#done
		return 0
	fi

	# all other commands require USER
	if [[ ! "$2" ]]; then
		usage
		exit 1
	fi

	case $1 in
		#	add
		# Add a new user; Enable a previously disabled user; Validate a user.
		# An active user can ONLY log in via SSH, to a git-shell.
		add)
			# if no user, create
			if ! getent passwd | grep $1 >/dev/null; then
				adduser --shell /usr/bin/git-shell --disabled-password --gecos "" "$2"
			# otherwise, force git-shell
			else
				usermod -s /usr/bin/git-shell "$2"
			fi
			# ensure there are no enabled git-shell commands
			rm -f "/home/$2/git-shell-commands"

			# Force proper SSH directory structure.
			mkdir -p "/home/$2/.ssh"
				poop=$?; if (( $poop )); then exit $poop; fi
			# If user was previously disabled, restore the "disabled" file
			#+	in ~/.ssh
			if [[ -e "/home/$2/.ssh/disabled" ]]; then
				mv "/home/$2/.ssh/disabled" "/home/$2/.ssh/authorized_keys"
				poop=$?; if (( $poop )); then exit $poop; fi
			fi
	
			# optional: add key entry
			if [[ "$KEY_" ]]; then
				echo "no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-user-rc $KEY_" \
					>> "/home/$2/.ssh/authorized_keys"
				poop=$?; if (( $poop )); then exit $poop; fi
			# if not at least timestamp 'authorized_keys'
			else
				touch "/home/$2/.ssh/authorized_keys"
				poop=$?; if (( $poop )); then exit $poop; fi
			fi

			# force ownership and permissions
			chown -R "$2": "/home/$2/.ssh"
			chmod -R ugo-rwx,u+rX "/home/$2/.ssh"

			# enable any commented-out mount entries for user
			sed -i"" -r 's|^#('"$REPO_BASE"'.*/home/'"$2"'.*)|\1|g' /etc/fstab
			# update mounts
			mount -a
			;;

		#	disable
		# To disable a user, rename their authorized_keys file
		disable)
			# user must exist
			if ! getent passwd | grep $1 >/dev/null; then
				echo "Cannot find user '$2' to be disabled" >&2
				exit 1
			fi

			# rename authorized_keys file
			if [[ -e "/home/$2/.ssh/authorized_keys" ]]; then
				mv "/home/$2/.ssh/authorized_keys" "/home/$2/.ssh/disabled"
				poop=$?; if (( $poop )); then exit $poop; fi
			fi

			# unmount repos (recurse)
			user umount "$2"
			# disable any mount entries for user
			sed -i"" -r 's|^('"$REPO_BASE"'.*/home/'"$2"'.*)|#\1|g' /etc/fstab
			;;

		#	rem
		# Remove a user entirely
		rem|del|delete)
			# user must exist
			if ! getent passwd | grep $1 >/dev/null; then
				echo "Cannot find user '$2' to be removed" >&2
				exit 1
			fi
			# remove user
			deluser "$2"
				poop=$?; if (( $poop )); then exit $poop; fi

			# unmount repos (recurse)
			user umount "$2"
			# remove all mount entries
			sed -i"" -r '\|.*'"/home/$2"'.*| d' fstab

			# remove home dir
			rm -rf "/home/$2"
				poop=$?; if (( $poop )); then exit $poop; fi
			;;

		#	umount
		# unmount any mounted repos for USER
		umount)
			mount | grep "/home/$2" | cut -d ' ' -f 3 | xargs -I{} umount -v {}
			;;
		
		*)
			echo "Unknown command '$1'" >&2
			usage
			exit 1
			;;
	esac
}


#	auth()
#		$1	:	{ls|add|rem}
#		$2	:	USER
#		$3	:	REPO
auth()
{
	# must at least have a command
	if [[ ! "$1" ]]; then
		usage
		exit 1
	fi

	# 	list
	# Show either active or inactive authorizations
	if [[ "$1" == "ls" || "$1" == "list" ]]; then
		if [[ ! $INACTIVE_ ]]; then
			sed -rn 's|^'"$REPO_BASE"'/([^\t]+)\t/home/([^/]+).*|\2\t\1|p' /etc/fstab
		else
			sed -rn 's|^#'"$REPO_BASE"'/([^\t]+)\t/home/([^/]+).*|\2\t\1|p' /etc/fstab
		fi
		return 0
	fi

	# all other calls must give USER and REPO
	if [[ ! "$2" || ! "$3" ]]; then
		usage
		exit 1
	fi
	# user must exist
	if ! getent passwd | grep $2 >/dev/null; then
		echo "user '$2' doesn't exist" >&2
		exit 1
	fi
	# repo must exist
	if [[ ! -d "$REPO_BASE/$3" ]]; then
		echo "repo '$3' doesn't exist" >&2
		exit 1
	fi
	# remove all spaces from repo
	$3=$(echo "$3" | sed 's/ /_/g')

	case $1 in
		#	add
		# Allow/verify that user $2 can access repo $3
		add)
			# add user to repo-specific group so they can write?
			if [[ ! $READ_ ]]; then
				usermod -s /usr/bin/git-shell -a -G "git_$3" "$2"
				poop=$?; if (( $poop )); then exit $poop; fi
			fi

			# make sure a mountpoint exists for the bind mount
			mkdir -p "/home/$2/$3"
				poop=$?; if (( $poop )); then exit $poop; fi
			# make sure fstab entry exists for bind mount, 
			#+	use 'while' to ensure its printed either way
			while ! grep -E "/home/$2/$3" /etc/fstab; do
				printf "$REPO_BASE/$3\t/home/$2/$3\tnone\tbind,noexec\t0\t0" >>/etc/fstab
				sort -o /etc/fstab /etc/fstab
			done
			# update mounts
			mount -a
				poop=$?; if (( $poop )); then exit $poop; fi
			;;

		#	rem
		# Remove access to repo $3 for user $2
		rem|del|delete)
			# unmount bind if mounted
			if mount | grep "/home/$2/$3" >/dev/null; then
				umount -f "/home/$2/$3"
				poop=$?; if (( $poop )); then exit $poop; fi
			fi

			# remove entry from fstab
			sed -i"" -r '\|/home/'"$2/$3"'| d' /etc/fstab

			# remove user from group
			deluser "$2" "git_$3"
			;;

		*)
			echo "Unknown command '$1'" >&2
			usage
			exit 1
			;;
	esac
}


##
# 	main
##
check_platform
case $1 in
repo)
	repo "$2" "$3"
	;;
user)
	user "$2" "$3"
	;;
auth)
	auth "$2" "$3"
	;;
*)
	usage
	exit 1
	;;
esac