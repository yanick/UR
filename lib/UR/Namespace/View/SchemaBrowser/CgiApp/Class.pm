package UR::Namespace::View::SchemaBrowser::CgiApp::Class;

use strict;
use warnings;
require UR;
our $VERSION = "0.40"; # UR $VERSION;

use base 'UR::Namespace::View::SchemaBrowser::CgiApp::Base';

use Class::Inspector;

sub setup {
my($self) = @_;
#$DB::single = 1;
    $self->start_mode('show_class_page');
    $self->mode_param('rm');
    $self->run_modes(
            'show_class_page' => 'show_class_page',
    );
}

sub show_class_page {
my $self = shift;
#$DB::single = 1;

    my @namespace_names = $self->GetNamespaceNames();
    my $namespace_name = $self->namespace_name;

    $self->tmpl->param(SELECTED_NAMESPACE => $namespace_name);
    $self->tmpl->param(NAMESPACE_NAMES => [ map { { NAMESPACE_NAME => $_,
                                                    SELECTED => ($_ eq $namespace_name),
                                                  } }
                                            @namespace_names
                                           ]);

    return $self->tmpl->output() unless ($namespace_name);

    my $namespace = UR::Namespace->get($namespace_name);

    my $class_name = $self->request->Env('classname') || '';
    my @all_class_names = $namespace->get_material_class_names();

    $self->tmpl->param(SELECTED_CLASS => $class_name);
    $self->tmpl->param(CLASS_NAMES => [ map { { CLASS_NAME => $_,
                                                SELECTED => ($_ eq $class_name),
                                                LINK_PARAMS => join('&', "namespace=$namespace_name",
                                                                         "classname=$_"),
                                                URL => 'class.html',
                                             } }
                                        @all_class_names
                                      ]);

    return $self->tmpl->output() unless ($class_name);

    my $class_obj = UR::Object::Type->get(namespace => $namespace_name, class_name => $class_name);
    $self->tmpl->param(SELECTED_CLASS_TABLE => defined($class_obj) && $class_obj->table_name);
    $self->tmpl->param(CLASS_IS_UR => $class_obj ? 1 : 0);

    my %class_properties;
    if ($class_obj) {
        my @class_detail;
        foreach my $prop_name ( qw( namespace doc er_role is_abstract is_final is_singleton
                                    sub_classification_meta_class_name subclassify_by) ) {

            push @class_detail, { PROPERTY_NAME => $prop_name, PROPERTY_VALUE => $class_obj->$prop_name };
        }
        push @class_detail, { PROPERTY_NAME => 'data_source',
                              PROPERTY_VALUE => UR::Context->resolve_data_source_for_object($class_obj)};
        $self->tmpl->param(CLASS_DETAIL => \@class_detail);
    
        my @class_properties;
        my %id_properties = map { $_ => 1 } $class_obj->all_id_property_names;
        foreach my $prop_obj ( $class_obj->all_property_metas ) {
            next if ($prop_obj->property_name eq 'id');   # FIXME what if the 'id' property is real and not autogenerated?
            $class_properties{$prop_obj->property_name} = 1;
            push @class_properties, { PROPERTY_NAME => $prop_obj->property_name,
                                      PROPERTY_TYPE => $prop_obj->data_type,
                                      PROPERTY_LENGTH => $prop_obj->data_length,
                                      IS_ID_PROPERTY => $id_properties{$prop_obj->property_name} || 0,
                                    };
        }
        $self->tmpl->param(CLASS_PROPERTIES => \@class_properties);
    }

    my $filename = Class::Inspector->loaded_filename($class_name);
    $self->tmpl->param('FILENAME' => $filename);

    my $method_sort_col;
    my $method_sorter = $self->request->Env('method_sorter') || 'method';
    if ($method_sorter eq 'class') {
        $method_sort_col = 1;  # Sort by what class the method is defined in
        $self->tmpl->param(SORT_METHODS_BY_CLASS => 1);
        $self->tmpl->param(SORT_METHODS_BY_NAME => 0);
    } else {
        $method_sort_col = 2;  # Sort by the method name
        $self->tmpl->param(SORT_METHODS_BY_NAME => 1);
        $self->tmpl->param(SORT_METHODS_BY_CLASS => 0);
    }

    $self->tmpl->param('CLASS_INHERIT' => $self->_MakeClassInheritance($class_name));

    my $pub_method_list = Class::Inspector->methods($class_name, 'public','expanded');
    my $priv_method_list = Class::Inspector->methods($class_name,'private','expanded');

    $self->tmpl->param('CLASS_PUBLIC_METHODS' => [ map { { CLASS_NAME => $_->[1],
                                                           METHOD_NAME => $_->[2],
                                                           NAMESPACE => $namespace_name,
                                                           OVERRIDES => [ $self->GetMethodOverrides($_->[1], $_->[2]) ],
                                                           $self->GetMethodLocation($_),
                                                       }}
                                                  sort {$a->[$method_sort_col] cmp $b->[$method_sort_col]}
                                                  @$pub_method_list
                                              ]);


    $self->tmpl->param('CLASS_PRIVATE_METHODS' => [ map { { CLASS_NAME => $_->[1],
                                                            METHOD_NAME => $_->[2],
                                                            NAMESPACE => $namespace_name,
                                                            OVERRIDES => [ $self->GetMethodOverrides($_->[1], $_->[2]) ],
                                                            $self->GetMethodLocation($_),
                                                        }}
                                                  sort {$a->[$method_sort_col] cmp $b->[$method_sort_col]}
                                                  @$priv_method_list
                                               ]);
    return $self->tmpl->output();
}


# Given a listref that would be returned as one item of Class::Inspector->methods
# ['Class::method1','Class','method1',\&Class::method1]
# Return a hash with keys FILENAME => pathanme of file the class is in
# and LINENO => line in the file that this method is defined in
# This requires that the debugger flags $^P were turned on before the
# module was loaded
sub GetMethodLocation {
my($self,$methodinfo) = @_;
    my $name = $methodinfo->[0];
    my $info = $DB::sub{$name};

    return () unless $info;
    my ($file,$start,$end);
    if ($info =~ m/\[(.*?):(\d+)\]/) {  # This should match eval's and __ANON__s
        ($file,$start,$end) = ($1,$2,$2);

    } elsif ($info =~ m/(.*?):(\d+)-(\d+)$/) {
        ($file,$start,$end) = ($1,$2,$3);

    }

    return (FILENAME => $file, LINENO => $start);
}



# Given a listref that would be returned as one item of Class::Inspector->methods
# ['Class::method1','Class','method1',\&Class::method1]
# Return a hash with keys CLASS_NAME => class_name as a result of searching the
# inheritance hirarchy for other classes where this method name was defined
# and therfore overridden
sub GetMethodOverrides {
my($self,$class_name,$method) = @_;

    my @results;
    my %seen;
    my @isa = ($class_name);
    while (@isa) {
        my $superclass = shift @isa;
        next if $seen{$superclass};
        $seen{$superclass} = 1;

        if (Class::Inspector->function_exists($superclass, $method)) {
            push @results, { CLASS_NAME => $superclass };
        }
        {   no strict 'vars';
            push @isa, eval '@' . $class_name . '::ISA';
        }
    }

    shift @results;  # Throw out the first one.  It'll be reported as the real method call
    return @results;
}



sub _MakeClassInheritance {
my($self,$starting_class_name) = @_;
    my $recurse_sub;
    my $maxdepth = 0;
    my @retval = ();
    my $namespace = $self->request->Env('namespace');

    $recurse_sub = sub {
        my($class_name,$depth) = @_;

        $maxdepth = $depth if ($depth > $maxdepth);

        my @isa_list;
        {   no strict 'refs';
            @isa_list = @{"${class_name}::ISA"};
        }

        return () unless @isa_list;

        unshift(@retval, { DEPTH => $depth,
                           NAMESPACE => $namespace,
                           CLASS_NAME => $class_name,
                         });
        foreach my $subclass ( @isa_list ) {
            $recurse_sub->($subclass, $depth + 1);
        }
    };

    $recurse_sub->($starting_class_name, 1);


    # Alter the 'depth' value at each node so the base class becomes
    # depth 1, and the original class is the deepest
    $maxdepth--;
    foreach my $node ( @retval ) {
        $node->{'DEPTH'} = $maxdepth - $node->{'DEPTH'};
        $node->{'DEPTH_L'} = [ 1 .. $node->{'DEPTH'} ];
    }

    return \@retval;
}


sub _template{
q(
<HTML><HEAD><TITLE>Class Browser<TMPL_IF NAME="SELECTED_CLASS">: <TMPL_VAR NAME="SELECTED_CLASS"></TMPL_IF></TITLE></HEAD>
<BODY>
<TABLE border=0>
<TR><TD>
        <FORM method="GET">
            Namespace: <SELECT name="namespace">
                <TMPL_LOOP NAME=NAMESPACE_NAMES>
                    <OPTION <TMPL_IF NAME="SELECTED">selected</TMPL_IF>
                            label="<TMPL_VAR ESCAPE=HTML NAME="NAMESPACE_NAME">"
                            value="<TMPL_VAR ESCAPE=HTML NAME="NAMESPACE_NAME">" >
                        <TMPL_VAR NAME="NAMESPACE_NAME">
                     </OPTION>
                </TMPL_LOOP>
            </SELECT><BR>
            Class name: <INPUT TYPE=text name="classname"><BR>
            <INPUT type="submit" name="Go" value="Go">
        </FORM>
</TD></TR>
<TR><TD>
        <TABLE border=1>
            <TR><TD width="20%" valign=top>

                    <! The list of Class names on the left>

                    <TMPL_IF NAME="SELECTED_NAMESPACE">
                        <TABLE border=0>
                            <TMPL_LOOP NAME="CLASS_NAMES">
                                <TR><TD align=left>
                                        <TMPL_IF NAME="SELECTED">
                                            <TMPL_VAR ESCAPE=HTML NAME="CLASS_NAME">
                                        <TMPL_ELSE>
                                            <A HREF="<TMPL_VAR NAME="URL">?<TMPL_VAR NAME="LINK_PARAMS">">
                                                 <TMPL_VAR ESCAPE=HTML NAME="CLASS_NAME">
                                            </A>
                                        </TMPL_IF>
                                </TD></TR>
                            </TMPL_LOOP>
                        </TABLE>
                    </TMPL_IF>
            </TD>
            <TD valign=top>
                <TMPL_IF NAME="SELECTED_CLASS">
                   <TABLE border=0>
                        <TR><TD><H2><TMPL_VAR NAME="SELECTED_CLASS"></H2></TD>
                            <TD><TMPL_IF NAME="SELECTED_CLASS_TABLE">
                                    <A HREF="schema.html?namespace=<TMPL_VAR NAME="SELECTED_NAMESPACE">&tablename=<TMPL_VAR NAME="SELECTED_CLASS_TABLE">">Table <TMPL_VAR NAME="SELECTED_CLASS_TABLE"></A>
                                <TMPL_ELSE>
                                     No related table
                                </TMPL_IF>
                            </TD>
                        </TR>
                    </TABLE>
                    <! Link to the loaded file for this class>
                    <P>
                        <TMPL_IF NAME="FILENAME">
                            Loaded from file <A HREF="file.html?filename=<TMPL_VAR NAME="FILENAME">"><TMPL_VAR NAME="FILENAME"></A>
                        <TMPL_ELSE>
                            No related module file
                        </TMPL_IF>
                    </P>

                    <BR>
                    <! Class inheritance tree>
                    <STRONG>Class Interitance</STRONG><BR>
                        <TMPL_LOOP NAME="CLASS_INHERIT">
                            <TMPL_LOOP NAME="DEPTH_L"> <UL> </TMPL_LOOP>
                                <LI>
                                    <A HREF="class.html?namespace=<TMPL_VAR NAME="SELECTED_NAMESPACE">&classname=<TMPL_VAR NAME="CLASS_NAME">"><TMPL_VAR NAME="CLASS_NAME"></A>
                                </LI>
                            <TMPL_LOOP NAME="DEPTH_L"> </UL> </TMPL_LOOP>
                        </TMPL_LOOP>

                    <TMPL_IF NAME="CLASS_IS_UR">
                        <STRONG>Class Metadata Information</STRONG>
                        <BR>
                        <TABLE border=0>
                            <TMPL_LOOP NAME="CLASS_DETAIL">
                                <TR><TD><TMPL_VAR NAME="PROPERTY_NAME"></TD>
                                    <TD><TMPL_VAR NAME="PROPERTY_VALUE"></TD>
                                </TR>
                            </TMPL_LOOP>
                        </TABLE>

                        <P>
    
                        <STRONG>Class Properties</STRONG>
                        <BR>
                        <TABLE border=1>
                            <TR><TH align=left>Property Name</TH>
                                <TH align=left>Data Type</TH>
                                <TH align=left>Data Length</TH>
                            <TR>
                            <TMPL_LOOP NAME="CLASS_PROPERTIES">
                                <TR><TD><TMPL_IF NAME="IS_ID_PROPERTY"><B></TMPL_IF>
                                              <TMPL_VAR NAME="PROPERTY_NAME"></B>
                                    </TD>
                                    <TD><TMPL_VAR NAME="PROPERTY_TYPE"></TD>
                                    <TD><TMPL_VAR NAME="PROPERTY_LENGTH"></TD>
                                </TR>
                            </TMPL_LOOP>
                        </TABLE>
                    </TMPL_IF>

                    <! Public method list>
                    <P>
                    <TABLE border=1>
                        <TR><TH align=left>
                                <TMPL_IF NAME="SORT_METHODS_BY_NAME">
                                    Public Methods
                                <TMPL_ELSE>
                                    <A HREF="class.html?namespace=<TMPL_VAR NAME="SELECTED_NAMESPACE">&classname=<TMPL_VAR NAME="SELECTED_CLASS">&method_sorter=method">Public Methods</A>
                                </TMPL_IF>
                            </TH>
                            <TH>
                                <TMPL_IF NAME="SORT_METHODS_BY_CLASS">
                                    Interited From
                                <TMPL_ELSE>
                                    <A HREF="class.html?namespace=<TMPL_VAR SELECTED_NAMESPACE>&classname=<TMPL_VAR SELECTED_CLASS>&method_sorter=class">Inherited from</A>
                                </TMPL_IF>
                            </TH></TR>

                        <TMPL_LOOP NAME="CLASS_PUBLIC_METHODS">
                            <TR><TD><TMPL_IF NAME="FILENAME">
                                        <A HREF="file.html?filename=<TMPL_VAR NAME="FILENAME">#line<TMPL_VAR NAME="LINENO">">
                                        <TMPL_VAR NAME="METHOD_NAME"></A>
                                    <TMPL_ELSE>
                                        <TMPL_VAR NAME="METHOD_NAME">
                                    </TMPL_IF>
                                </TD>
                                <TD><A HREF="class.html?namespace=<TMPL_VAR NAME="NAMESPACE">&classname=<TMPL_VAR NAME="CLASS_NAME">"><TMPL_VAR NAME="CLASS_NAME"></A>
                                    <BR>
                                    <UL><TMPL_LOOP NAME="OVERRIDES">
                                        <LI><A HREF="class.html?namespace=<TMPL_VAR NAME="NAMESPACE">&classname=<TMPL_VAR NAME="CLASS_NAME">"><TMPL_VAR NAME="CLASS_NAME"></A></LI>
                                    </TMPL_LOOP></UL>

                                </TD>
                            </TR>
                        </TMPL_LOOP>
                    </TABLE>
                    </P>

                    <! Private method list>
                    <P>
                    <TABLE border=1>
                        <TR><TH align=left colspan=10>Private Methods</TH></TR>
                        <TMPL_LOOP NAME="CLASS_PRIVATE_METHODS">
                            <TR><TD><TMPL_IF NAME="FILENAME">
                                        <A HREF="file.html?filename=<TMPL_VAR NAME="FILENAME">#line<TMPL_VAR NAME="LINENO">">
                                        <TMPL_VAR NAME="METHOD_NAME"></A>
                                    <TMPL_ELSE>
                                        <TMPL_VAR NAME="METHOD_NAME">
                                    </TMPL_IF>
                                </TD>
                                <TD><A HREF="class.html?namespace=<TMPL_VAR NAME="NAMESPACE">&classname=<TMPL_VAR NAME="CLASS_NAME">"><TMPL_VAR NAME="CLASS_NAME"></A>
                                    <BR>
                                    <UL><TMPL_LOOP NAME="OVERRIDES">
                                        <LI><A HREF="class.html?namespace=<TMPL_VAR NAME="NAMESPACE">&classname=<TMPL_VAR NAME="CLASS_NAME">"><TMPL_VAR NAME="CLASS_NAME"></A></LI>
                                    </TMPL_LOOP></UL>
                                </TD>
                            </TR>
                        </TMPL_LOOP>
                    </TABLE>
                    </P>

                <TMPL_ELSE>
                    <! No SELECTED_CLASS yet>
                    Please select a class on the left
                </TMPL_IF>
            </TD></TR>
        </TABLE>
</TD></TR>
</TABLE>
</BODY>
)};


1;
