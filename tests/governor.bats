#!/usr/bin/env bats
#
# The governor module, and in particular the frequency/voltage curve: the
# profile only decides how far up the upstream curve to go, it never invents
# a point of its own.

load helper

setup() {
	sandbox_setup
	lib_source
	fake_bc250
	layered_boot cyan-skillfish-governor-smu
}

gov_config() { cat "$BC250_PREFIX/etc/cyan-skillfish-governor-smu/config.toml"; }

@test "the curve is cut at the profile's frequency and voltage caps" {
	use_profile balanced
	run bc250ctl configure governor
	[ "$status" -eq 0 ]

	run gov_config
	[[ $output == *"frequency = 1500"* ]]   # kept: 1500 MHz at 900 mV
	[[ $output != *"frequency = 1600"* ]]   # dropped: 910 mV is over the cap
	[[ $output != *"frequency = 2000"* ]]
	[[ $output == *"min = 1000"* ]]
	[[ $output == *"max = 1500"* ]]
}

@test "a higher voltage cap admits more of the curve" {
	use_profile max
	run bc250ctl configure governor
	[ "$status" -eq 0 ]

	run gov_config
	[[ $output == *"frequency = 1600"* ]]
	[[ $output != *"frequency = 1700"* ]]   # above max.env's 1600 MHz cap
}

@test "a cap that leaves no usable point is an error, not an empty curve" {
	write_config <<-EOC
		BC250_GOV_FREQ_MIN=200
		BC250_GOV_FREQ_MAX=400
		BC250_GOV_VOLT_MIN=600
		BC250_GOV_VOLT_MAX=650
	EOC
	run bc250ctl configure governor
	[ "$status" -ne 0 ]
	[[ $output == *"no point on the governor curve fits"* ]]
}

@test "configuring enables the service" {
	use_profile balanced
	bc250ctl configure governor
	run grep -c cyan-skillfish-governor-smu.service "$MOCK_STATE/units-enabled"
	[ "$output" -ge 1 ]
}

@test "install enables the COPR with GPG checking on" {
	use_profile safe
	bc250ctl install governor
	local repo="$BC250_PREFIX/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:filippor:bazzite.repo"
	[ -f "$repo" ]
	grep -q '^gpgcheck=1' "$repo"
	grep -q 'filippor/bazzite/pubkey.gpg' "$repo"
}

@test "verify resolves the BC-250 to card1, not blindly to card0" {
	use_profile balanced
	bc250ctl configure governor
	run bc250ctl verify governor
	[ "$status" -eq 0 ]
	[[ $output == *"BC-250 GPU is card1"* ]]
}

@test "verify fails when the service is not running" {
	use_profile balanced
	run bc250ctl verify governor
	[ "$status" -ne 0 ]
	[[ $output == *"is not running"* ]]
}
