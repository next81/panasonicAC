#
#	50_PanasonicAC.pm 
#
#	(c) 2022 Andreas Planer (https://forum.fhem.de/index.php?action=profile;u=45773)
#


package main;
use strict;
use warnings;
use JSON qw( encode_json decode_json );
use HttpUtils;
use experimental 'smartmatch';

# Standard Header für Abfrage auf accsmart.panasonic.com
my $PanasonicAC =	{	"header"	=> {"x-app-type" => "1", 
										"accept" => "application/json; charset=utf-8", 
										"user-agent" => "G-RAC",
										"content-type" => "application/json; charset=utf-8",
										"content-length" => 0,
										"accept-encoding" => "gzip",
										"x-app-name" => "Comfort Cloud",
										"x-app-timestamp" => "1",
										"x-cfc-api-key" => "Comfort Cloud"
										}
	};

###################################################################################################
# Main
###################################################################################################

sub PanasonicAC_Initialize($) {
	my ($hash) = @_;

	$hash->{DefFn}		= "PanasonicAC_Define";
	$hash->{UndefFn}	= "PanasonicAC_Undefine";
	$hash->{NotifyFn}	= "PanasonicAC_Notify";
	$hash->{SetFn}		= "PanasonicAC_Set";
	$hash->{WriteFn}	= "PanasonicAC_Write";
	$hash->{AttrFn}		= "PanasonicAC_Attr";
	$hash->{Clients}	= "PanasonicACDevice";
	$hash->{AttrList}	= "interval timeout delayAfterWrite version loginId disable:0,1 ".$readingFnAttributes;

	
	# sicher stellen, dass auch 51_PanasonicACDevice.pm geladen ist
	PanasonicAC_loadPanasonicACDevice();

	return undef;
}

sub PanasonicAC_Define($$) {
	my ($hash, $def) = @_;
    my @param = split('[ \t]+', $def);
	my $caller = (caller(1))[3];

	$hash->{'.version'}			= "1.17.0"; # Default Version
	$hash->{'.interval'}		= 60; # Default Interval
	$hash->{'.timeout'}			= 30; # Default Timeout
	$hash->{'.delayAfterWrite'}	= 2; # Default Delay
    $hash->{name}				= $param[0];

	$attr{$hash->{name}}{room} = "PanasonicAC";
	Log3 $hash->{NAME}, 4, "PanasonicAC (".$hash->{NAME}."): PanasonicAC_Define() called by $caller";

	readingsSingleUpdate($hash, "state", "defined", 1);

	# Mit der APP API der Panasonic Comfort Cloud verbinden
	PanasonicAC_Connect($hash);

	$modules{PanasonicAC}{defptr}{$hash->{NAME}} = \$hash;

	return undef;
}

sub PanasonicAC_Undefine($$) {
	my ($hash, $name) = @_;
  	my $index 	= $hash->{TYPE}."_".$hash->{NAME}."_passwd";
	my $caller	= (caller(1))[3];

	Log3 $hash->{NAME}, 4, "PanasonicAC (".$hash->{NAME}."): PanasonicAC_Undefine() called by $caller";

	RemoveInternalTimer($hash);
	delete $hash->{timer};
 
	Log3 $hash->{NAME}, 5, "PanasonicAC (".$hash->{NAME}.") deleting device";

	my $err = setKeyValue($index, undef);
	
	return "PanasonicAC (".$hash->{NAME}."): error while saving the password - $err" if(defined($err));

	return undef;
}

sub PanasonicAC_Notify($$) {
	my ($hash, $hashDevice) = @_;
	my $name		= $hash->{NAME};
	my $deviceName	= $hashDevice->{NAME};
	my $caller		= (caller(1))[3];

	return "" if(IsDisabled($name));
	
}

sub PanasonicAC_Set($@) {
	my ($hash, @param) = @_;
	my $setKeys = ["password"];

	return '"set $name" needs at least one argument' 
		if (int(@param) < 2);

	my $name	= shift @param;
	my $cmd		= shift @param;
	my $value	= join("", @param);
	my $caller	= (caller(1))[3];

	Log3 $hash->{NAME}, 4, "PanasonicAC (".$hash->{NAME}.") PanasonicAC_Set() called by $caller";
	
	if ($cmd ~~ $setKeys) {

		if ($cmd eq "password" && $value ne "") {
			Log3 $hash->{NAME}, 4, "PanasonicAC (".$hash->{NAME}."): PanasonicAC_Set saving password";

			PanasonicAC_storePassword($hash, $value);
			
			if (AttrVal($name, "loginId", "") ne "") {
				PanasonicAC_Connect($hash);
			}
			
			return undef;
		} 
	}
	else {
		return "Unknown argument $cmd, choose one of password";
	}
}

sub PanasonicAC_Write($$) {
	my ( $hash, $deviceGuid, $cmd, $value) = @_;
	my $caller = (caller(1))[3];
	
	Log3 $hash->{NAME}, 4, "PanasonicAC (".$hash->{NAME}."): PanasonicAC_Write() called by $caller";
	Log3 $hash->{NAME}, 5, "PanasonicAC (".$hash->{NAME}."): PanasonicAC_Write: (deviceGuid: ".$deviceGuid." cmd:$cmd, value:".(defined($value) ? $value : "");

	my $data->{deviceGuid} = $deviceGuid;
	my $hashRef = $modules{PanasonicACDevice}{defptr}{PanasonicAC_GetId($deviceGuid)};
	my $deviceName = $$hashRef->{NAME};
	

	# der Operationsmode wird von der API immer (unnötig) gesetzt, also machen wir das auch
	$data->{parameters}{operationMode} = ReadingsVal($hashRef, "operationMode", undef) if (defined(ReadingsVal($hashRef, "operationMode", undef)));

	if ($cmd eq "off") {
		$data->{parameters}{operate} = 0;
	} elsif ($cmd eq "on") {
		$data->{parameters}{operate} = 1;
	} elsif ($cmd eq "desired-temp" && $value >= -1 && $value <= 40) {
		$data->{parameters}{temperatureSet} = $value;
	} elsif ($cmd eq "operationMode" && $value >= 0 && $value <= 4) {
		$data->{parameters}{operationMode} = $value;
		# fanSpeed und temperatureSet werden (redundant) von der App mit verschickt, also setzen wir diese auch
		$data->{parameters}{fanSpeed} = ReadingsVal($hashRef, "fanSpeed", undef) if (defined(ReadingsVal($hashRef, "fanSpeed", undef)));
		$data->{parameters}{temperatureSet} = ReadingsVal($hashRef, "desired-temp", undef) if (defined(ReadingsVal($hashRef, "desired-temp", undef)));
	} elsif ($cmd eq "fanSpeed" && $value >= 0 && $value <= 5) {
		$data->{parameters}{fanSpeed} = $value;
	} elsif ($cmd eq "ecoMode" && $value >= 0 && $value <= 2) {
		$data->{parameters}{ecoMode} = $value;
		# die App setzt ecoNavi + iAuto, wenn quiet oder power Modus aktiviert wird, nicht aber bei Normal (= 0)
		if ($value > 0) {
			$data->{parameters}{ecoNavi} = ReadingsVal($deviceName, "ecoNavi", undef) if (defined(ReadingsVal($deviceName, "ecoNavi", undef)));
			$data->{parameters}{ecoNavi} = ReadingsVal($deviceName, "iAuto", undef) if (defined(ReadingsVal($deviceName, "iAuto", undef)));
		}
	} elsif ($cmd eq "airSwingUD" && $value >= 0 && $value <= 4) {
		$data->{parameters}{airSwingUD} = $value;
	} elsif ($cmd eq "airSwingLR" && $value >= 0 && $value <= 5 && $value != 3) {
		$data->{parameters}{airSwingLR} = $value;

	} elsif ($cmd eq "fanAutoMode" && $value >= 0 && $value <= 3) {
		$data->{parameters}{fanAutoMode} = $value;
		$data->{parameters}{airSwingUD} = ReadingsVal($deviceName, "airSwingUD", 2);
		$data->{parameters}{airSwingLR} = ReadingsVal($deviceName, "airSwingLR", 2);
		#ecoNavi wird gesetzt, wenn airSwingLR auf Auto gestellt wird (fanautomode == 0,2)
		$data->{parameters}{ecoNavi} = ReadingsVal($deviceName, "ecoNavi", undef) if (defined(ReadingsVal($deviceName, "ecoNavi", undef)));

	}
	
	PanasonicAC_requestAPI(	$hash, "write", {	deviceGuid => $deviceGuid,
												data => PanasonicAC_encodeJson($hash, $data)
											});

	# Wenn ein Write bei einem PanasonicACDevice erfolgt, soll state auf updating gesetzt werden, welcher erst vom Callback wieder auf on/off gesetzt wird.
	$$hashRef->{".lastState"} = AttrVal($$hashRef, "state", "") if (AttrVal($$hashRef, "state", "") ne "updating");
	readingsSingleUpdate($$hashRef, "state", "updating", 1);
	
	return undef;
}

sub PanasonicAC_Attr($$$$) {
	my ( $cmd, $name, $aName, $aValue ) = @_;
    my $hash = $defs{$name};
	
	if ($cmd eq "set") {
		if ($aName eq "interval") {
			return "Interval less than 60s is not allowed!" if ($aValue < 60);
		} elsif ($aName eq "timeout") {
			return "timeout have to be > 1s and lower than 60s" if ($aValue < 1 || $aValue > 60);
		} elsif ($aName eq "delayAfterWrite") {
			return "delayAfterWrite have to be > 1s and lower than 60s" if ($aValue < 1 || $aValue > 60);
		}
	}
	
	if ($aName eq "disable") {
		if ($cmd eq "set" && $aValue == 1) {
			RemoveInternalTimer($hash);
			readingsSingleUpdate($hash, "state", "disable", 1);

			Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_Set disabled $aValue";
		} elsif ($cmd eq "del") {
			readingsSingleUpdate($hash, "state", "enabled", 1);
			InternalTimer(gettimeofday() + 1, "PanasonicAC_Connect", $hash);
		}
	} elsif ($aName eq "version") { # Beim Setzen der Version wird ein neuer Connect ausgeführt, da bei Fehlermeldung einer neuen Version der Reconnect unterbunden wird
		InternalTimer(gettimeofday() + 1, "PanasonicAC_Connect", $hash);
	}
	
	return undef;
}

# Kommunuikation mit der APP API der Panasonic Comfort Cloud
sub PanasonicAC_requestAPI {
	my ($hash, $cmd, $data) = @_;
	my ($paramCmd);
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];

	Log3 $name, 4, "PanasonicAC (".$name."): PanasonicAC_requestAPI (cmd: $cmd) called by $caller";

	# keine Requests an API senden, wenn Modul disabled
	return "" if(IsDisabled($name));

	# bei $cmd != login wird API nur abgefragt, wenn Verbindung besteht
	if (ReadingsVal($name, "state", "") eq "connected" || $cmd eq "login")
	{
		if ($cmd eq "login") {
			# alten uToken löschen
			delete $PanasonicAC->{header}{"x-user-authorization"};
			
			$paramCmd = {	url 		=> "https://accsmart.panasonic.com/auth/login",
							method		=> "POST",
							callback	=> \&PanasonicAC_ConnectCallback
						};
		} elsif ($cmd eq "getGroup") {
			$paramCmd = {	url			=> "https://accsmart.panasonic.com/device/group",
							method		=> "GET",
							callback	=> \&PanasonicAC_GetGroupCallback
						};
		} elsif ($cmd eq "get") {
			$paramCmd = {	url			=> "https://accsmart.panasonic.com/deviceStatus/now/".$data->{deviceGuid},
							deviceGuid	=> $data->{deviceGuid},
							deviceName	=> $data->{deviceName},
							method		=> "GET",
							callback	=> \&PanasonicAC_GetCallback
						};
		} elsif ($cmd eq "write") {
			$paramCmd = {	url			=> "https://accsmart.panasonic.com/deviceStatus/control",
							deviceGuid	=> $data->{deviceGuid},
							method		=> "POST",
							callback	=> \&PanasonicAC_WriteCallback
						};

		} else {
			Log3 $hash, 3, "PanasonicAC (".$name.") PanasonicAC_requestAPI $cmd not matching any case";
			return undef;
		}

		$PanasonicAC->{header}{'x-app-version'} = AttrVal($name, "version", $hash->{'.version'});
		$PanasonicAC->{header}{'content-length'} = defined($data->{data}) ? length($data->{data}) : 0;
		
		# PComfortCloud setzt nur beim Login + Write UTF-8 im Content-Type. Ggf. ändern auf GET/POST?
		if ($cmd eq "login" || $cmd eq "write") {
			$PanasonicAC->{header}{"content-type"} = "application/json; charset=utf-8";
		} else {
			$PanasonicAC->{header}{"content-type"} = "application/json;";
		}


		# Standardwerte für alle Requests ergänzen
		my $param = {	%$paramCmd,
						timeout		=> AttrVal($name, "timeout", $hash->{'.timeout'}),
						hash		=> $hash,
						header		=> $PanasonicAC->{header},
						data		=> $data->{data}
					};

		HttpUtils_NonblockingGet($param);
		
	} else {
		Log3 $name, 4, "PanasonicAC ($name): calling PanasonicAC_connect";
		PanasonicAC_Connect($hash);
	}
	
	return undef;
}

# Connect zur Panasonic Comfort Cloud
sub PanasonicAC_Connect($) {
	my ($hash)	= @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];

	Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_Connect() called by $caller";

	# Alle laufenden Timer entfernen
	RemoveInternalTimer($hash);
	delete $hash->{timer};

	# keine Verbindung herstellen, wenn Modul disabled
	return "" if(IsDisabled($name));
	
	my $data = {	clientId	=> PanasonicAC_getClientId($hash), 
					language 	=> 0,
					loginId		=> AttrVal($name, "loginId", ""),
					password	=> PanasonicAC_readPassword($hash)
				};

	# Nach Interval neu prüfen, wenn logindaten nicht vollständig  
	if ($data->{loginId} eq "" || $data->{password} eq "") {

		readingsSingleUpdate($hash, "state", "no password set", 1) if ($data->{password});
		readingsSingleUpdate($hash, "state", "loginId missing", 1) if ($data->{loginId} eq "");

		Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_Connect new interval with ".AttrVal($name, "interval", $hash->{'.interval'}."s");
		InternalTimer(gettimeofday() + AttrVal($name, "interval", $hash->{'.interval'}), "PanasonicAC_Connect", $hash);
		
		return undef;
	}
	
	# Session (uToken) holen 
	PanasonicAC_requestAPI($hash, "login", {data => PanasonicAC_encodeJson($hash, $data)});
	
	return 1;
}

# Alle im Account konfiguierten Geräte auslesen
sub PanasonicAC_GetGroup($) {
	my ($hash)	= @_;
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];

	Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_GetGroup() called by $caller";

	PanasonicAC_requestAPI($hash, "getGroup");
	
	# Timestamp des letzten Durchlauf speichern
	$hash->{lastUpdateCycle} = time();

	# neuen Timer starten in einem konfigurierten Interval
	Log3 $name, 4, "PanasonicAC ($name): GetGroup new interval with ".AttrVal($name, "interval", $hash->{'.interval'}."s");
	InternalTimer(gettimeofday() + AttrVal($name, "interval", $hash->{'.interval'}), "PanasonicAC_GetGroup", $hash);
}

sub PanasonicAC_Get($$) {
	my ($hash, $device) = @_;
	my $name			= $hash->{NAME};
	my $caller			= (caller(1))[3];
	
	Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_Get() called by $caller";

	PanasonicAC_requestAPI($hash, "get", {	deviceGuid => $device->{deviceGuid},
											deviceName => $device->{deviceName}
											});
	
	return 1;
}	

sub PanasonicAC_checkDetails($) {
	my ($guid)	= @_;
	my $hashDeviceRef	= $modules{PanasonicACDevice}{defptr}{PanasonicAC_GetId($guid)};
	my $hashRef			= $modules{PanasonicAC}{defptr}{$$hashDeviceRef->{IODev}{NAME}};

	delete $$hashRef->{timer}{$guid};
	
	if (defined($hashDeviceRef)) {
		my $name			= $$hashDeviceRef->{NAME}; # Name des PanasonicACDevice
		my $intervalDetails	= AttrVal($name, "intervalDetails", undef);
		
		Log3 $name, 4, "PanasonicAC_checkDetails ($name) called";
		
		if (defined($intervalDetails)) {

			my $lastRequestDetails	= $$hashDeviceRef->{lastRequestDetails} ? $$hashDeviceRef->{lastRequestDetails} : 0;
			my $timeElapsed			= time() - $lastRequestDetails;
		
			Log3 $name, 5, "PanasonicAC_checkDetails ($name): lastRequestDetails: $lastRequestDetails timeElapsed: $timeElapsed intervalDetails: $intervalDetails";

			if ($timeElapsed > $intervalDetails) {
				Log3 $name, 4, "PanasonicAC_checkDetails ($name): calling PanasonicAC_Get for $name";
				
				$$hashDeviceRef->{lastRequestDetails} = time();

				PanasonicAC_Get($$hashDeviceRef->{IODev}, { deviceGuid => $guid } );

			} else {
				Log3 $name, 4, "PanasonicAC_checkDetails ($name): timeElapsed ($timeElapsed) is smaller than intervalDetails ($intervalDetails). skipping";
			}
		} else {
			Log3 $name, 4, "PanasonicAC_checkDetails ($name): no attribute intervalDetails found";
		}
	} else {
		Log3 undef, 3, "PanasonicAC_checkDetails: no hashDeviceRef found";
	}
	return undef;
}

###################################################################################################
# Callbacks
###################################################################################################

sub PanasonicAC_WriteCallback($) {
	my ($param, $err, $content) = @_;

	my $hash	= $param->{hash};
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	my $device->{deviceGuid}	= $param->{deviceGuid};
	my $hashDeviceRef			= $modules{PanasonicACDevice}{defptr}{PanasonicAC_GetId($device->{deviceGuid})};
	
	Log3 $hash, 4, "PanasonicAC ($name): PanasonicAC_WriteCallback() called by $caller";
	Log3 $hash, 5, "PanasonicAC ($name): PanasonicAC_WriteCallback content: $content";

	# Den Status wieder zurücksetzen
	readingsSingleUpdate($$hashDeviceRef, "state", $$hashDeviceRef->{".lastState"}, 1) if (AttrVal($$hashDeviceRef, "state", "") eq "updating");
	
	
	# Daten des Device mit 2s Verzögerung aktualisieren, nachdem die Daten geschrieben wurden, da die API scheinbar selbst etwas Zeit benötigt, bis sie die Werte aktualisiert
	InternalTimer(gettimeofday() + AttrVal($name, "delayAfterWrite", $hash->{'.delayAfterWrite'}), "PanasonicAC_DelayedGet", $device->{deviceGuid});
}

sub PanasonicAC_ConnectCallback($) {
	my ($param, $err, $content) = @_;

	my $hash	= $param->{hash};
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	
	Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_ConnectCallback() called by $caller";

	# Alle Timer müssen entfernt sein, da neue gestartet werden! 
	RemoveInternalTimer($hash);
	delete $hash->{timer};

	if ($err ne "") {
		Log3 $name, 3, "PanasonicAC ($name): error while requesting ".$param->{url}." - $err";
    }
	elsif ($content ne "") {
		Log3 $name, 5, "PanasonicAC ($name): PanasonicAC_ConnectCallback received content: $content";

		my $decoded_json = PanasonicAC_decodeJson($hash, $content);

		if (defined($decoded_json)) {
			if ($decoded_json->{"uToken"}) {
				Log3 $name, 5, "$name: uToken (".$decoded_json->{uToken}.") found!";
				
				$hash->{uToken} = $decoded_json->{"uToken"};
				$PanasonicAC->{header}{"x-user-authorization"} = $hash->{"uToken"};

				readingsSingleUpdate($hash, "state", "connected", 1);

				Log3 $name, 3, "PanasonicAC ($name): connected to Panasonic Comfort Cloud API";
				PanasonicAC_GetGroup($hash);
			} else {
				Log3 $name, 3, "PanasonicAC ($name): error. uToken not found!";
				readingsSingleUpdate($hash, "state", "uToken error", 1);
			}
			
		} else {
			Log3 $name, 3, "PanasonicAC ($name): error. no JSON code received: ($content)";
		}
		
	}
}

sub PanasonicAC_GetCallback($) {
	my ($param, $err, $content) = @_;

	my $hash	= $param->{hash};
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];

	Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_GetCallback() called by $caller";
	Log3 $name, 5, "PanasonicAC ($name): PanasonicAC_GetCallback content: $content";

	if ($err ne "") {
		Log3 $name, 3, "PanasonicAC ($name): error while requesting ".$param->{url}." - $err";
    } elsif ($content ne "") {
	
		my $decoded_json = PanasonicAC_decodeJson($hash, $content);

		if (defined($decoded_json)) {
			
			$decoded_json->{deviceGuid} = $param->{deviceGuid};
			$decoded_json->{deviceName} = $param->{deviceName} if (defined($param->{deviceName}));

			$content = PanasonicAC_encodeJson($hash, $decoded_json);

			if (defined($content)) {
				Dispatch($hash, $content);
			} else {
				return undef;
			}
		} else {
			Log3 $name, 3, "PanasonicAC ($name): error. no decoded JSON ($content)";
		}
	}
}

sub PanasonicAC_GetGroupCallback($) {
	my ($param, $err, $content) = @_;

	my $hash	= $param->{hash};
	my $name	= $hash->{NAME};
	my $caller	= (caller(1))[3];
	
	Log3 $name, 4, "PanasonicAC ($name): PanasonicAC_GetGroupCallback() called by $caller";

	if ($err ne "") {
		Log3 $name, 3, "PanasonicAC ($name): error while requesting ".$param->{url}." - $err";
    }
	elsif ($content ne "") {
		Log3 $name, 5, "PanasonicAC ($name): PanasonicAC_GetGroupCallback received content: $content";

		my $decoded_json = PanasonicAC_decodeJson($hash, $content);

		if (defined($decoded_json)) {

			foreach my $device (@{$decoded_json->{groupList}[0]{deviceList}}) {

				my $hashDeviceRef = $modules{PanasonicACDevice}{defptr}{PanasonicAC_GetId($device->{deviceGuid})};

				Log3 $name, 4, "PanasonicAC ($name): found device ".makeReadingName($$hashDeviceRef->{NAME}).", model: ".($device->{deviceModuleNumber} ? $device->{deviceModuleNumber} : "").", deviceGuid: ".$device->{deviceGuid};

				my $deviceContent = PanasonicAC_encodeJson($hash, $device);

				if (defined($deviceContent)) {

					Dispatch($hash, $deviceContent);


					# CheckDetails wird nur ausgeführt, wenn für das Device das Attribut intervalDetails gesetzt ist 
					if (AttrVal($$hashDeviceRef->{NAME}, "intervalDetails", undef)) {

						# checkDetails nur ausführen, wenn noch kein Timer für diese Guid läuft
						if (!$hash->{timer}{$device->{deviceGuid}}) {

							# Prüfen ob Details für Temperaturwerte abgefragt werden sollen 
							my $lastCheckDetails = $hash->{lastCheckDetails} ? $hash->{lastCheckDetails} : time();
							$lastCheckDetails = time() if ($lastCheckDetails < time());
							
							# Wir wollen wenigstens 15 Sekunden zwischen den einzelnen API Requests, um ein Block durch die API zu vermeiden 
							$hash->{lastCheckDetails} = $lastCheckDetails + 15;
							$hash->{timer}{$device->{deviceGuid}} = $hash->{lastCheckDetails};
							
							Log3 $name, 4, "PanasonicAC_checkDetails for ".$device->{deviceGuid}." in ".($hash->{lastCheckDetails} - time())."s";
							InternalTimer($hash->{lastCheckDetails}, "PanasonicAC_checkDetails", $device->{deviceGuid});
						} else {
							Log3 $name, 4, "PanasonicAC_checkDetails (".$$hashDeviceRef->{NAME}."): timer already active";
						}
					} else {
						if (defined($$hashDeviceRef->{NAME})) {
							Log3 $name, 4, "PanasonicAC_checkDetails (".$$hashDeviceRef->{NAME}."): Attribute intervalDetails not set";
						}
					}
				} else {
					Log3 $name, 3, "PanasonicAC ($name): error encoding JSON";
					return undef;
				}
			}
		}
	}
}


###################################################################################################
# Helper
###################################################################################################

sub PanasonicAC_getClientId($) {
	my ($hash) = @_;
	my ($clientId); 
	
	# Wir erzeugen eine zufällige clientId für den Login, wenn noch keine gesetzt ist
	if (defined($hash->{clientId})) {
		$clientId = $hash->{clientId};
	} else {
		my @set = ('0' ..'9', 'A' .. 'Z', 'a' .. 'z');
		my $str = join '' => map $set[rand @set], 1 .. 42;
		$clientId = "CR".$str."qdmsm";
		$hash->{clientId} = $clientId;
	}

	return $clientId;
}

sub PanasonicAC_DelayedGet($) {
	my ($guid) = @_;

	my $hashDeviceRef	= $modules{PanasonicACDevice}{defptr}{PanasonicAC_GetId($guid)};
	my $hashRef			= $modules{PanasonicAC}{defptr}{$$hashDeviceRef->{IODev}{NAME}};

	PanasonicAC_Get($$hashRef, {deviceGuid => $guid});
}

sub PanasonicAC_Reconnect($) {
	my ($hash)	= @_;
	my $name	= $hash->{NAME};

	Log3 $name, 3, "PanasonicAC ($name): reconnect in ".$hash->{'.interval'}."s";
	
	RemoveInternalTimer($hash);
	readingsSingleUpdate($hash, "state", "reconnecting", 1);
	
	# Mindestens 2 Min Delay 
	my $interval = AttrVal($name, "interval", $hash->{'.interval'}) > 120 ? AttrVal($name, "interval", $hash->{'.interval'}) : 120;
	
	# Reconnect nach Interval
	InternalTimer(gettimeofday() + $interval, "PanasonicAC_Connect", $hash);
}

# API Result decodieren 
sub PanasonicAC_decodeJson($$) {
	my ($hash, $content) = @_;
	my $decoded_json;
	my $caller	= (caller(1))[3];
	my $name	= $hash->{NAME};
	
	Log3 $name, 4, "PanasonicAC (".$name."): PanasonicAC_decodeJson() called by $caller";
	
	eval '$decoded_json = decode_json($content);';
	
	# Fehler prüfen, wenn $content kein valides JSON enthielt
	if ($@) {
		Log3 $name, 3, "PanasonicAC (".$name."): $caller returned error: $@ content: $content";

		# Todo
		# 505 HTTP Version Not Supported

		# bei E403 neu mit API verbinden
		if ($content =~ m/403 Forbidden/) {
			Log3 $name, 3, "PanasonicAC (".$name."): $caller 403 Forbidden.";

			readingsSingleUpdate($hash, "state", "Login blocked (403 Forbidden)", 1);
		} 
		elsif ($content =~ m/502 Bad Gateway/) {
			Log3 $name, 3, "PanasonicAC (".$name."): $caller 502 Bad Gateway.";

			readingsSingleUpdate($hash, "state", "API down (502 Bad Gateway)", 1);
		}
		
		PanasonicAC_Reconnect($hash);

		return undef;
	}

	# Errorcode prüfen, falls vorhanden
	if (defined($decoded_json->{code})) {
		if ($decoded_json->{code} == 4100) {
			Log3 $name, 3, "PanasonicAC ($name): token expired";

			readingsSingleUpdate($hash, "state", "token expired", 1);
			PanasonicAC_Reconnect($hash);
		}
		elsif ($decoded_json->{code} == 4000) {
			Log3 $name, 3, "PanasonicAC ($name): Missing required header parameter or bad request for header";

			readingsSingleUpdate($hash, "state", "Missing required header parameter or bad request for header", 1);
			PanasonicAC_Reconnect($hash);
		}
		elsif ($decoded_json->{code} == 4101) {
			Log3 $name, 3, "PanasonicAC ($name): Login ID or password is incorrect,or account is locked";

			readingsSingleUpdate($hash, "state", "Login ID or password is incorrect,or account is locked", 1);
			RemoveInternalTimer($hash);
		}
		elsif ($decoded_json->{code} == 4106) { # neue Version wurde veröffentlicht
			Log3 $name, 3, "PanasonicAC ($name): New version app has been published. Update attribute version!";

			readingsSingleUpdate($hash, "state", "New version app has been published. Update attribute version!", 1);
			RemoveInternalTimer($hash);
		}	
		elsif ($decoded_json->{code} == 5005) {
			Log3 $name, 3, "PanasonicACDevice ($name): Adapter Communication error";
			PanasonicAC_Reconnect($hash);
		}
		
		
		return undef;
	}
	
	return $decoded_json;
}

# API Data encodieren 
sub PanasonicAC_encodeJson($$) {
	my ($hash, $content) = @_;
	my $json;
	my $caller	= (caller(1))[3];
	my $name	= $hash->{NAME};
	
	Log3 $name, 4, "PanasonicAC (".$name."): PanasonicAC_encodeJson() called by $caller";
	
	eval '$json = encode_json($content);';
	
	# Fehler prüfen, wenn $content nicht in JSON umgewandelt werden konnte
	if ($@) {
		Log3 $name, 3, "PanasonicAC (".$name."): $caller returned error: $@ content: $content";
		
		return undef;
	}
	
	return $json;
}

# Laden der PanasonicACDevice Funktionen		
sub PanasonicAC_loadPanasonicACDevice() {
	if( !$modules{PanasonicACDevice}{LOADED}) {
		my $ret = CommandReload(undef, "51_PanasonicACDevice");
		Log3 undef, 1, "loadPanasonicACDevice: $ret" if( $ret );
	}
}

# DeviceId aus der Guid extrahieren
sub PanasonicAC_GetId($) {
	my ($id) = @_;

	# Der Unique Key besteht aus Modell+Guid. Wir wollen nur die Guid.
	$id =~ s/^.*\+//g;
	return $id;
}

# Gernerierung eines kompatiblen deviceNames
sub PanasonicAC_MakeDeviceName($) {
	my ($name) = @_;

	return makeDeviceName("PanasonicAC.".PanasonicAC_GetId($name));
}

# Passwort verschlüsselt im key<>value Store speichern 
sub PanasonicAC_storePassword($$) {
	my ($hash, $password) = @_;
	my $name	= $hash->{NAME};
	my $index	= $hash->{TYPE}."_".$hash->{NAME}."_passwd";
	my $key		= getUniqueId().$index;
	my $enc_pwd	= "";

	if(eval "use Digest::MD5;1") {
		$key = Digest::MD5::md5_hex(unpack "H*", $key);
		$key.= Digest::MD5::md5_hex($key);
	}

	for my $char (split //, $password) {
		my $encode = chop($key);
		$enc_pwd.= sprintf("%.2x",ord($char)^ord($encode));
		$key = $encode.$key;
	}

	my $err = setKeyValue($index, $enc_pwd);
	return "PanasonicAC ($name): error while saving the password - $err" if(defined($err));

	return "PanasonicAC ($name): password successfully saved";
} 

# Passwort aus key<>value Store lesen und entschlüsseln 
sub PanasonicAC_readPassword($) {
	my ($hash)	= @_;
	my $name	= $hash->{NAME};
	my $index	= $hash->{TYPE}."_".$hash->{NAME}."_passwd";
	my $key		= getUniqueId().$index;
	my ($password, $err);

	Log3 $name, 5, "Read PanasonicAC password from file";

	($err, $password) = getKeyValue($index);

	if ( defined($err) ) {
		Log3 $name, 5, "unable to read PanasonicAC password from file: $err";
		return undef;
	}

	if ( defined($password) ) {
		if ( eval "use Digest::MD5;1" ) {
			$key = Digest::MD5::md5_hex(unpack "H*", $key);
			$key.= Digest::MD5::md5_hex($key);
		}

		my $dec_pwd = '';

		for my $char (map { pack('C', hex($_)) } ($password =~ /(..)/g)) {
			my $decode = chop($key);
			$dec_pwd.= chr(ord($char)^ord($decode));
			$key = $decode.$key;
		}
		return $dec_pwd;
	} else {
		Log3 $name, 5, "No password in file";
		return undef;
	}
}


1;


# Beginn der Commandref

=pod
=item device
=item summary Steuerung einer Panasonic Klimaanlage über die Panasonic Comfort Cloud
=begin html

<a name="PanasonicAC"></a>
<h3>PanasonicAC</h3>
<ul>
	<br>
	<a name="PanasonicAC_Set"></a>
	<b>set</b><br>
	<ul>
		<li>
			<code>set &lt;name&gt; &lt;value&gt;</code><br>
		</li>
		<a name="password"></a>
		<li>
			speichert das Passwort verschlüsselt im internen keyValue Store
			<code>set &lt;name&gt; password &lt;Passwort&gt;</code><br><br>

			Beispiel:<br>
			<code>set &lt;name&gt; password HalloWelt</code> # Passwort "HalloWelt" 
		</li>
		<a name="interval"></a>
		<li>
			<code>attr &lt;name&gt; interval &lt;Sekunden&gt;</code><br><br>
			Wenn dieses Attribut gesetzt ist, dann wird die Panasonic Comfort Cloud in diesem Interval aktualisiert. Ist das Attribut nicht gesetzt wird der Defaultwert von 60s genommen.<br><br>
			zulässige Values:<br>
			&gt;60<br><br>

			Beispiel:<br>
			<code>set &lt;name&gt; interval 120</code> # Abfrage der API alle 2 Minuten
		</li>		
		<a name="loginId"></a>
		<li>
			<code>attr &lt;name&gt; loginId &lt;E-Mail&gt;</code><br><br>
			Hier muss die E-Mail Adresse des Panasonic Comfort Cloud Accounts gesetzt werden.<br><br>

			Beispiel:<br>
			<code>attr &lt;name&gt; loginId hallo@mail.de</code>
		</li>		
		<a name="version"></a>
		<li>
			<code>attr &lt;name&gt; version &lt;Versionsnummer&gt;</code><br><br>
			Hier kann eine abweichende Versionsnummer definiert werden, die an die API übergeben wird (Header Parameter "X-APP-VERSION"). Default wird als Version "1.15.1" verwendet. Da die API bei einer unpassenden Version einen Fehler zurückgibt und nicht funktioniert, kann hierüber die Version angepasst werden ohne das Modul aktualisieren zu müssen.<br><br>

			Beispiel:<br>
			<code>attr &lt;name&gt; version 1.15.1</code> # setzen der Version auf "1.15.1"
		</li>		
		<a name="delayAfterWrite"></a>
		<li>
			<code>attr &lt;name&gt; delayAfterWrite &lt;[1-60]&gt;</code><br><br>
			Nach dem Schreiben auf ein PanasonicACDevice muss der neue Status abgefragt werden. Um zu viele Abfragen hintereinander zu vermeiden, wird der Status des PanasonicACDevice verzögert aktualisiert. Default 2s.<br><br>

			Beispiel:<br>
			<code>attr &lt;name&gt; delayAfterWrite 5</code> # Aktualisiert den Status 5s nach einem Write
		</li>		

	</ul>
</ul>
<a name="PanasonicAC_Define"></a>
define
<a name="PanasonicAC_Attr"></a>
attr
=end html


# Ende der Commandref
=cut
