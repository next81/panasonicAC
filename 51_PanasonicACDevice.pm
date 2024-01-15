#
#	50_PanasonicACDevice.pm 
#
#	(c) 2022 Andreas Planer (https://forum.fhem.de/index.php?action=profile;u=45773)
#


package main;
use strict;
use warnings;
use experimental 'smartmatch';

###################################################################################################
# Main
###################################################################################################

sub PanasonicACDevice_Initialize($) {
	my ($hash) = @_;

	$hash->{DefFn}		= "PanasonicACDevice_Define";
	$hash->{UndefFn}	= "PanasonicACDevice_Undefine";
	$hash->{SetFn}		= "PanasonicACDevice_Set";
	$hash->{AttrFn}		= "PanasonicACDevice_Attr";
    $hash->{ParseFn}	= "PanasonicACDevice_Parse";
    $hash->{Match}		= ".+";

	$hash->{noAutocreatedFilelog} = 1;
	$hash->{AutoCreate} = 	{"PanasonicAC\..*"	=> {ATTR   				=> 'event-on-change-reading:.* event-min-interval:.*:300 room:PanasonicAC icon:sani_heating_heatpump devStateIcon:{PanasonicACDevice_devStateIcon($name)}',
													autocreateThreshold	=> '1:60'
													}
							};

	$hash->{AttrList} = "intervalDetails ".$readingFnAttributes;
}

sub PanasonicACDevice_Define($$) {
	my ($hash, $def) = @_;
	my @param = split('[ \t]+', $def);

	if (int(@param) < 3) {
		return "too few parameters: define <name> PanasonicACDevice <deviceGuid>";
	}

	$hash->{name}		= $param[0];
	$hash->{deviceGuid}	= $param[2];
    $hash->{Interval}	= 300; # Default Interval für Temperaturabfragen

	# Referenz auf $hash unter der deviceGuid anlegen
	$modules{PanasonicACDevice}{defptr}{PanasonicAC_GetId($hash->{deviceGuid})} = \$hash;

	AssignIoPort($hash);

	return undef;
}

sub PanasonicACDevice_Undefine($$)
{
	my ($hash, $name) = @_;
 
	return undef;
}

sub PanasonicACDevice_Set($$) {
	my ( $hash, $name, $cmd, $value ) = @_;
	my $setKeys = ["on", "off", "desired-temp", "airSwingUD", "airSwingLR", "fanSpeed", "operationMode", "ecoMode", "fanAutoMode"];
	my $caller = (caller(1))[3];

	if ($cmd ne "?") {
		Log3 $hash->{NAME}, 4, "PanasonicACDevice (".$hash->{NAME}."): PanasonicACDevice_Set() called by $caller";

		return "\"set $name\" needs at least one argument"  unless(defined($cmd));

		Log3 $hash->{NAME}, 5, "PanasonicACDevice (".$hash->{NAME}."): (".$hash->{deviceGuid}." - (cmd: $cmd) - (value: ".(defined($value) ? $value : "").")) start";
	}

	if ($cmd ~~ $setKeys) {
		my $result = IOWrite($hash, $hash->{deviceGuid}, $cmd, $value);
	}
	else {
		return "Unknown argument $cmd, choose one of on:noArg off:noArg desired-temp operationMode ecoMode fanSpeed airSwingUD airSwingLR fanAutoMode";
	}
}

sub PanasonicACDevice_Attr($$$$) {
	my ( $cmd, $name, $aName, $aValue ) = @_;
    
	if ($cmd eq "set") {
		if ($aName eq "intervalDetails") {
			return "Interval less than 300s is not allowed!" if ($aValue < 300);
		} elsif ($aName eq "desired-temp") {
			return "desired-temp have to be between -1°C and 40°C!" if (!defined($aValue) || $aValue < -1 || $aValue > 40);

			my $fract = $aValue - int($aValue);
			return "wrong value for desired-temp. only 0.5°C steps are allowed." if ($fract == 0 || $fract == 0.5);
			
		}
	}
	return undef;
}


sub PanasonicACDevice_Parse ($$) {
	my ($IOhash, $data) = @_;    # IOhash = PanasonicAC, nicht PanasonicACDevice

    my $name			= $IOhash->{NAME};
	my $decoded_json	= decode_json($data); # kein Eval benötigt, da $data in 50_PanasonicAC mit encode_json erstellt wurde
	my $guid			= $decoded_json->{deviceGuid};
	my $deviceName		= "";
#	my @operationMode 	= ("Auto", "Dry", "Cool", "Heat", "Fan");
#	my @fanSpeed 		= ("Auto", 1, 2, 3, 4, 5);
#	my @ecoMode 		= ("Auto", "Power", "Quiet");
#	my @airSwingUD 		= ("Up", "Down", "Middle", "UpMiddle", "DownMiddle");
#	my @airSwingLR 		= ("Left", "Right", "Middle", undef, "LeftMiddle", "RightMiddle");
#	my @fanAutoMode		= ("H:auto,V:auto", "H:man,V:man", "H:auto,V:man", "H:man,V:auto");
	my $caller 			= (caller(1))[3];

	Log3 $name, 4, "PanasonicACDevice: PanasonicACDevice_parse() called by $caller";
	Log3 $name, 5, "PanasonicACDevice: PanasonicACDevice_parse received content: $data";

	if (defined($guid)) {
		# $hashRef ist eine Referenz auf $hash des jeweiligen Devices
		my $hashRef = $modules{PanasonicACDevice}{defptr}{PanasonicAC_GetId($guid)};

		# $hash existiert nur, wenn das Device schon angelegt wurde
		if ($hashRef)
		{
			$deviceName = $$hashRef->{NAME};

			Log3 $deviceName, 4, "PanasonicACDevice ($deviceName): existing device Id ".PanasonicAC_GetId($guid);
		
			readingsBeginUpdate($$hashRef);
			readingsBulkUpdateIfChanged($$hashRef, "state", (($decoded_json->{parameters}{operate} == 1) ? "on" : "off") );
			readingsBulkUpdateIfChanged($$hashRef, "desired-temp", $decoded_json->{parameters}{temperatureSet});
			readingsBulkUpdateIfChanged($$hashRef, "ecoNavi", $decoded_json->{parameters}{ecoNavi});
			readingsBulkUpdateIfChanged($$hashRef, "fanSpeed", $decoded_json->{parameters}{fanSpeed});
			readingsBulkUpdateIfChanged($$hashRef, "ecoMode", $decoded_json->{parameters}{ecoMode});
			readingsBulkUpdateIfChanged($$hashRef, "operationMode", $decoded_json->{parameters}{operationMode});

			# fanAutoMode
			# Hier muss zwingend auch airSwingUD/LR gesetzt werden, da die API den Wert sonst nicht verarbeitet
			# 0 - H:auto,V:auto
			# 1 - H:manual,V:manual
			# 2 - H:auto,V:manual
			# 3 - H:manual,V:auto
			readingsBulkUpdateIfChanged($$hashRef, "fanAutoMode", $decoded_json->{parameters}{fanAutoMode});
			readingsBulkUpdateIfChanged($$hashRef, "airSwingUD", $decoded_json->{parameters}{airSwingUD});
			readingsBulkUpdateIfChanged($$hashRef, "airSwingLR", $decoded_json->{parameters}{airSwingLR});

			# Die Nachrüsterweiterung CZ-TACG1 kann die Innentemperatur nicht ermitteln und liefert immer 126 °C zurück, daher reading nicht schreiben
			if (defined($decoded_json->{parameters}{insideTemperature}) && $decoded_json->{parameters}{insideTemperature} != 126) {
				readingsBulkUpdateIfChanged($$hashRef, "temperature", $decoded_json->{parameters}{insideTemperature});
			}

			if (defined($decoded_json->{parameters}{outTemperature}) && $decoded_json->{parameters}{outTemperature} != 126) {
				readingsBulkUpdateIfChanged($$hashRef, "temperatureOutdoorUnit", $decoded_json->{parameters}{outTemperature});
			}
			
			readingsEndUpdate($$hashRef, 1);

			# DeviceName als Array für dispatch() zurückgeben 
			return ($deviceName);
		}
		else
		{
			use Encode qw(decode);
			
			if ($decoded_json->{deviceName} ne "") {
				$deviceName = PanasonicAC_MakeDeviceName(decode("utf8", $decoded_json->{deviceName}));
			}
			
			# Wenn deviceName nicht gesetzt werden konnte oder Device mit dem Namen bereits existiert wird $guid zur Namensbildung genutzt
			if ($deviceName eq "" || $defs{$deviceName}) { 
				$deviceName = PanasonicAC_MakeDeviceName($guid);
			}
			
			Log3 $name, 4, "UNDEFINED $deviceName PanasonicACDevice $guid";

			# Keine Gerätedefinition verfügbar, Rückmeldung für AutoCreate
			return "UNDEFINED $deviceName PanasonicACDevice $guid";
		}
	} else {
		Log3 $name, 3, "PanasonicAC ($name): no deviceGuid found!";
	}                        

}


###################################################################################################
# GUI
###################################################################################################

sub PanasonicACDevice_devStateIcon($) {
	my ($name) = @_;
	my @operationMode 	= ("time_automatic", "humidity", "frost", "sani_heating", "Ventilator_fett");
	my $mode 			= ReadingsVal($name, "operationMode", undef);
	my $eventMap		= {'off' => 'off', 'on' => 'on'};
	my $eventMapSet		= AttrVal($name,"eventMap","");
	my (@map);
	
	if (defined($eventMapSet)) {
		my @parts = split /\s/, $eventMapSet;
		
		foreach (@parts) {
			@map = split /:/, $_;
			$eventMap->{$map[0]} = $map[1];
		}
	}

	if (defined($mode)) {
		return $eventMap->{off}.':'.$operationMode[$mode].'@grey '.$eventMap->{on}.':'.$operationMode[$mode].'@green updating:'.$operationMode[$mode].'@blue';
	} else {
		return undef;
	}
}


1;


# Beginn der Commandref

=pod
=item device
=item summary Steuerung einer Panasonic Klimaanlage über die Panasonic Comfort Cloud
=begin html

<a name="PanasonicACDevice"></a>
<h3>PanasonicACDevice</h3>
<ul>
	<br>
	<a name="PanasonicACDevice_Set"></a>
	<b>set</b><br>
	<ul>
		<li>
			<code>set &lt;name&gt; &lt;value&gt;</code><br>
		</li>
		<a name="airSwingLR"></a>
		<li>
			<code>set &lt;name&gt; airSwingLR &lt;0|1|2|4|5&gt;</code><br><br>
			zulässige Values:<br>
			0: Left<br>
			1: Right<br>
			2: Middle<br>
			4: LeftMiddle<br>
			5: RightMiddle<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; airSwingLR 0</code> # Luftrichtung nach links
		</li>
		<a name="airSwingUD"></a>
		<li>
			<code>set &lt;name&gt; airSwingUD &lt;0|1|2|3|4&gt;</code><br><br>
			zulässige Values:<br>
			0: Up<br>
			1: Down<br>
			2: Middle<br>
			3: UpMiddle<br>
			4: DownMiddle<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; airSwingUD 0</code> # Luftrichtung nach oben
		</li>
		<a name="ecoMode"></a>
		<li>
			<code>set &lt;name&gt; ecoMode &lt;0|1|2&gt;</code><br><br>
			zulässige Values:<br>
			0: Auto<br>
			1: Power<br>
			2: Quiet<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; ecoMode 2</code> # Klimagerät wird auf Flüstermodus (Quiet) gestellt
		</li>
		<a name="fanAutoMode"></a>
		<li>
			<code>set &lt;name&gt; fanAutoMode &lt;0|1|2|3&gt;</code><br><br>
			zulässige Values:<br>

			0: H:auto,V:auto<br>
			1: H:manual,V:manual<br>
			2: H:auto,V:manual<br>
			3: H:manual,V:auto<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; fanAutoMode 0</code> # Luftrichtigung Horizontal und Vertikal auf Automatik<br><br>
			Achtung: Beim setzen auf manuell werden die Luftrichtungen für Horizontal und Vertikal auf Mitte gesetzt!
		</li>
		<a name="fanSpeed"></a>
		<li>
			<code>set &lt;name&gt; fanSpeed &lt;0|1|2|3|4|5&gt;</code><br><br>
			zulässige Values:<br>

			0: Auto<br>
			1-5: Lüfterstufe<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; fanSpeed 3</code> # Lüfterstufe auf Stufe 3
		</li>		
		<a name="off"></a>
		<li>
			<code>set &lt;name&gt; off</code><br><br>
			schaltet des Klimagerät aus
		</li>		
		<a name="on"></a>
		<li>
			<code>set &lt;name&gt; on</code><br><br>
			schaltet das Klimagerät ein
		</li>		
		<a name="operationMode"></a>
		<li>
			<code>set &lt;name&gt; operationMode &lt;0|1|2|3|4&gt;</code><br><br>
			zulässige Values:<br>
			0: Auto<br>
			1: Dry<br>
			2: Cool<br>
			3: Heat<br>
			4: Fan<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; operationMode 2</code> # Klimaanlage auf Kühlen stellen<br><br>
			Achtung: Nicht alle Klimaanlagen unterstützen einen Mischbetrieb. Daher muss ggf. über ein Notify sichergestellt werden, dass alle Devices eines Aussengerätes im gleichen Modus betrieben werden! 
		</li>		
		<a name="desired-temp"></a>
		<li>
			<code>set &lt;name&gt; desired-temp &lt;-1 - 40&gt;</code><br><br>
			zulässige Values:<br>
			-1 °C bis 40 °C<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; desired-temp 22</code> # Klimaanlage auf Solltemperatur von 22° stellen<br><br>
		</li>		
		<a name="intervalDetails"></a>
		<li>
			<code>attr &lt;name&gt; intervalDetails &lt;Sekunden&gt;</code><br><br>
			Wenn dieses Attribut gesetzt ist, dann werden für dieses Device die Detaildaten im angegebenen Interval abgefragt. Dieser Wert sollte nicht auf unter 300s (=5 Minuten) gesetzt werden, da andernfalls zuviele Abfragen bei der Panasonic Comfort Cloud API passieren können, was schnell zu einem Block (Error 403) führen kann. Dieses Attribut sollte auch nur gesetzt werden, wenn die Klimaanlage über ein BuiltIn Wlan angeschlossen wurde. Die Nachrüstsetzs CS-TACG1 können nur die Aussentemperatur und nicht die Innentemperatur ermitteln.<br><br>
			zulässige Values:<br>
			&gt;300<br><br>
			Beispiel:<br>
			<code>set &lt;name&gt; intervalDetails 300</code> # Abfrage der Detaildaten alle 5 Minuten
		</li>		
		
	</ul>
</ul>

=end html

# Ende der Commandref
=cut