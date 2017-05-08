#!/bin/bash

# Where the version configs are generated
config_dir=config/versions
defaults=packages/default.desc

declare -A forks

debug()
{
	if [ -n "${DEBUG}" ]; then
		echo ":: $@" >&2
	fi
}

read_files()
{
	local f l

	for f in ${defaults} "$@"; do
		[ -r "${f}" ] || continue
		while read l; do
			case "${l}" in
				"#*") continue;;
				*) echo "[${l%%=*}]=${l#*=}";;
			esac
		done < "${f}"
	done
}

derived_package()
{
	info[name]=${p}
	info[forks]=${forks[${p}]}
	info[master]=${info[master]:-${p}}
	# Various kconfig-ized prefixes
	tmp=${p^^}
	info[pfx]=${tmp//[^0-9A-Z_]/_}
	tmp=${info[origin]^^}
	info[originpfx]=${tmp//[^0-9A-Z_/_}
	tmp=${info[master]^^}
	info[masterpfx]=${tmp//[^0-9A-Z_/_}
}

read_package_desc()
{
	read_files "packages/${1}/package.desc"
}

read_version_desc()
{
	read_files "packages/${1}/package.desc" "packages/${1}/${2}/version.desc"
}

for_each_package()
{
	local list="${1}"
	local -A info
	local p tmp

	debug "Entering: for_each_package $@"

	shift
	for p in ${list}; do
		eval "info=( `read_package_desc ${p}` )"
		derived_package ${p}
		debug "Evaluate for ${p}: $@"
		eval "$@"
	done
}

for_each_version()
{
	local pkg="${1}"
	local -A info prev
	local -a versions
	local v tmp

	debug "Entering: for_each_version $@"

	shift
	versions=( `cd packages/${pkg} && ls */version.desc 2>/dev/null | sed 's,/version.desc$,,' | sort -rV` )
	tmp=
	for v in "${versions[@]}"; do
		if [ -n "${tmp}" ]; then
			prev["${tmp}"]=${v}
		fi
		tmp="${v}"
	done
	
	if [ -n "${tmp}" ]; then
		prev["${tmp}"]=
	fi

	for v in "${versions[@]}"; do
		eval "info=( `read_version_desc "${pkg}" "${v}"` )"
		debug "INFO [[ `read_version_desc "${pkg}" "${v}"` ]]"
		derived_package ${pkg}
		info[ver]="${v}"
		info[kcfg]="${v//[^0-9A-Za-z_]/_}"
		info[prev]="${prev[${v}]//[^0-9A-Za-z_]/_}"
		debug "Evaluate for ${pkg}/${v}: $@"
		eval "$@"
	done
}

# Setup: find master-fork relationships between packages
find_forks()
{
	[ "${info[master]}" != "${info[name]}" ] && forks[${info[master]}]+=" ${info[name]}"
}

gen_versions()
{
	local cond=$1

	debug "Entering: gen_versions $@"

	if [ -n "${cond}" ]; then
		cat <<EOF
if ${cond}

EOF
	fi

	cat <<EOF
# Versions for ${info[name]}
choice
	bool
	prompt "Version of ${info[name]}"

# Defined versions first
EOF

	for_each_version "${info[name]}" echo \"'
config ${info[pfx]}_V_${info[kcfg]}
	bool \"${info[ver]}\"
	select ${info[pfx]}_V_${info[kcfg]}_or_later${info[obsolete]:+
	depends on OBSOLETE}${info[experimental]:+
	depends on EXPERIMENTAL}'\"

	if [ -n "${info[repository]}" ]; then
		cat <<EOF

config ${info[pfx]}_V_DEVEL
	bool "development"
	depends on EXPERIMENTAL
	help
	  Check out from the repository: ${info[repository]#* }
EOF
	fi

	# TBD custom (local tarball/directory)
	# TBD show custom location selection

	cat <<EOF

endchoice
EOF

	if [ -n "${info[repository]}" ]; then
		local -A dflt_branch=( [git]="master" [svn]="/trunk" )
		cat <<EOF

if ${info[pfx]}_V_DEVEL

config ${info[pfx]}_DEVEL_URL
	string
	default "${info[repository]}"

config ${info[pfx]}_DEVEL_BRANCH
	string "Branch to check out"
	default "${dflt_branch[${info[repository]%% *}]}"
	help
	  Git: branch to be checked out
	  Subversion: directories to append to the repository URL.

config ${info[pfx]}_DEVEL_REVISION
	string "Revision/changeset"
	default "HEAD"
	help
	  Commit ID or revision ID to check out.

endif

EOF
	fi

	cat <<EOF

# Text string with the version of ${info[name]}
config ${info[pfx]}_VERSION
	string
EOF
	for_each_version "${info[name]}" echo \
		\"'	default \"${info[ver]}\" if ${info[pfx]}_V_${info[kcfg]}'\"
 	cat <<EOF
	default "unknown"

EOF

	cat <<EOF

# Flags for all versions indicating "this or later".
# Only produced for master version of the package (which is what
# the build scriptes are tied to); derived versions must
# select the matching master version.
EOF
	for_each_version "${info[name]}" echo \"'
config ${info[pfx]}_V_${info[kcfg]}_or_later
	bool${info[prev]:+
	select ${info[pfx]}_V_${info[prev]}_or_later}'\"

	if [ -n "${cond}" ]; then
		cat <<EOF

endif

EOF
	fi
}

# Generate a menu for selecting a fork for a component
gen_selection()
{
	local only_obsolete=yes only_experimental=yes

	for_each_version "${info[name]}" '
[ -z "${info[experimental]}" ] && only_experimental=
[ -z "${info[obsolete]}" ] && only_obsolete=
'

	debug "${info[name]}: ${only_obsolete:+obsolete} ${only_experimental:+experimental}"

	echo "
config ${info[masterpfx]}_USE_${info[originpfx]}
	bool \"${info[origin]}\"${only_obsolete:+
	depends on OBSOLETE}${only_experimental:+
	depends on EXPERIMENTAL}
	help" && sed 's/^/\t  /' "packages/${info[origin]}.help"
}

# Generate a single configuration file
gen_one_component()
{
	local cond

	debug "Entering: gen_one_component $@"

	# Non-masters forks: skip, will be generated along with their master version
	if [ "${info[master]}" != "${info[name]}" ]; then
		debug "Skip '${info[name]}': master '${info[master]}'"
		return
	fi

	debug "Generating '${info[name]}.in'${info[forks]:+ (includes ${info[forks]}})"
	exec >"${config_dir}/${info[name]}.in"
	cat <<EOF
#
# DO NOT EDIT! This file is automatically generated.
#

EOF

	# Generate fork selection, if there is more than one fork
	if [ -n "${info[forks]}" ]; then
		cat <<EOF
choice
	bool "Show ${info[name]} versions from"
EOF
		for_each_package "${info[name]} ${info[forks]}" gen_selection

		cat <<EOF

endchoice

EOF
		for_each_package "${info[name]} ${info[forks]}" \
			gen_versions '${info[masterpfx]}_USE_${info[originpfx]}'
	else
		for_each_package "${info[name]}" gen_versions
	fi
}

rm -rf "${config_dir}"
mkdir -p "${config_dir}"

all_packages=`cd packages && ls */package.desc 2>/dev/null | sed 's,/package.desc$,,' | xargs echo`
debug "Generating package version descriptions"
debug "Packages: ${all_packages}"
for_each_package "${all_packages}" find_forks
for_each_package "${all_packages}" gen_one_component
debug "Done!"
