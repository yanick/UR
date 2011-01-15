package UR::Value::Blob;

use strict;
use warnings;

require UR;
our $VERSION = $UR::VERSION;

UR::Object::Type->define(
    class_name => 'UR::Value::Blob',
    is => ['UR::Value'],
    english_name => 'blob',
);

1;
#$Header$
