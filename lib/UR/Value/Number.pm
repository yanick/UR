package UR::Value::Number;

use strict;
use warnings;

require UR;
our $VERSION = $UR::VERSION;

UR::Object::Type->define(
    class_name => 'UR::Value::Number',
    is => ['UR::Value'],
    english_name => 'number',
);

1;
#$Header$
