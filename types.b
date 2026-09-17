// Postgres type OIDs, and turning a text-format field into a typed Value.
//
// Text format, not binary: every type has an exact text form, `numeric`
// survives it without rounding, and there is one decoder instead of one per
// OID pair. Binary is a later optimisation and needs a per-OID decoder for
// each of these; it lands when a benchmark says the parse cost matters.
package postgres

import github.com/beans-lang/dbcore

// The OIDs in pg_type.h with a frozen value — postgres promises these never
// change (https://www.postgresql.org/docs/current/datatype-oid.html).
pub const OID_BOOL: int = 16
pub const OID_BYTEA: int = 17
pub const OID_CHAR: int = 18
pub const OID_NAME: int = 19
pub const OID_INT8: int = 20
pub const OID_INT2: int = 21
pub const OID_INT4: int = 23
pub const OID_TEXT: int = 25
pub const OID_OID: int = 26
pub const OID_JSON: int = 114
pub const OID_XML: int = 142
pub const OID_FLOAT4: int = 700
pub const OID_FLOAT8: int = 701
pub const OID_BPCHAR: int = 1042
pub const OID_VARCHAR: int = 1043
pub const OID_DATE: int = 1082
pub const OID_TIME: int = 1083
pub const OID_TIMESTAMP: int = 1114
pub const OID_TIMESTAMPTZ: int = 1184
pub const OID_INTERVAL: int = 1186
pub const OID_NUMERIC: int = 1700
pub const OID_UUID: int = 2950
pub const OID_JSONB: int = 3802

pub const OID_BOOL_ARRAY: int = 1000
pub const OID_INT2_ARRAY: int = 1005
pub const OID_INT4_ARRAY: int = 1007
pub const OID_TEXT_ARRAY: int = 1009
pub const OID_VARCHAR_ARRAY: int = 1015
pub const OID_INT8_ARRAY: int = 1016
pub const OID_FLOAT4_ARRAY: int = 1021
pub const OID_FLOAT8_ARRAY: int = 1022
pub const OID_NUMERIC_ARRAY: int = 1231
pub const OID_UUID_ARRAY: int = 2951

pub fn type_name(oid: int) -> string {
    if oid == OID_BOOL { return "bool" }
    if oid == OID_BYTEA { return "bytea" }
    if oid == OID_CHAR { return "char" }
    if oid == OID_NAME { return "name" }
    if oid == OID_INT8 { return "int8" }
    if oid == OID_INT2 { return "int2" }
    if oid == OID_INT4 { return "int4" }
    if oid == OID_TEXT { return "text" }
    if oid == OID_OID { return "oid" }
    if oid == OID_JSON { return "json" }
    if oid == OID_JSONB { return "jsonb" }
    if oid == OID_XML { return "xml" }
    if oid == OID_FLOAT4 { return "float4" }
    if oid == OID_FLOAT8 { return "float8" }
    if oid == OID_BPCHAR { return "bpchar" }
    if oid == OID_VARCHAR { return "varchar" }
    if oid == OID_DATE { return "date" }
    if oid == OID_TIME { return "time" }
    if oid == OID_TIMESTAMP { return "timestamp" }
    if oid == OID_TIMESTAMPTZ { return "timestamptz" }
    if oid == OID_INTERVAL { return "interval" }
    if oid == OID_NUMERIC { return "numeric" }
    if oid == OID_UUID { return "uuid" }
    if is_array_oid(oid) { return "{element_name(oid)}[]" }
    return "oid{oid}"
}

pub fn is_array_oid(oid: int) -> bool { return element_oid(oid) != 0 }

/// The element OID of an array type, or 0 when this is not one of the array
/// types we name.
pub fn element_oid(oid: int) -> int {
    if oid == OID_BOOL_ARRAY { return OID_BOOL }
    if oid == OID_INT2_ARRAY { return OID_INT2 }
    if oid == OID_INT4_ARRAY { return OID_INT4 }
    if oid == OID_INT8_ARRAY { return OID_INT8 }
    if oid == OID_TEXT_ARRAY { return OID_TEXT }
    if oid == OID_VARCHAR_ARRAY { return OID_VARCHAR }
    if oid == OID_FLOAT4_ARRAY { return OID_FLOAT4 }
    if oid == OID_FLOAT8_ARRAY { return OID_FLOAT8 }
    if oid == OID_NUMERIC_ARRAY { return OID_NUMERIC }
    if oid == OID_UUID_ARRAY { return OID_UUID }
    return 0
}

fn element_name(oid: int) -> string { return type_name(element_oid(oid)) }

/// One field's text, as the server sent it, turned into a typed `Value`.
pub fn decode_text(oid: int, text: string) -> dbcore.Value {
    if oid == OID_BOOL { return dbcore.Value.of_bool(text == "t") }
    if oid == OID_INT2 || oid == OID_INT4 || oid == OID_INT8 ||
       oid == OID_OID {
        return dbcore.Value.of_int(text.to_int().or(0))
    }
    if oid == OID_FLOAT4 || oid == OID_FLOAT8 {
        return dbcore.Value.of_float(parse_float(text))
    }
    if oid == OID_NUMERIC { return dbcore.Value.of_decimal(text) }
    if oid == OID_BYTEA { return dbcore.Value.of_bytes(decode_bytea(text)) }
    if oid == OID_JSON || oid == OID_JSONB { return dbcore.Value.of_json(text) }
    if oid == OID_UUID { return dbcore.Value.of_uuid(text) }
    if is_array_oid(oid) {
        return dbcore.Value.of_array(decode_array(element_oid(oid), text))
    }
    return dbcore.Value.of_text(text)
}

// Postgres spells these three out; `to_float` does not know them.
fn parse_float(text: string) -> f64 {
    if text == "Infinity" { return 1.0 / 0.0 }
    if text == "-Infinity" { return -1.0 / 0.0 }
    if text == "NaN" { return 0.0 / 0.0 }
    return text.to_float().or(0.0)
}

/// `bytea_output = hex` is the default since 9.0: `\x48690a`. The older
/// escape form is still accepted, because a server can be set back to it.
pub fn decode_bytea(text: string) -> Bytes {
    var out: Bytes = new Bytes(0)
    if text.starts_with("\\x") {
        var index: int = 2
        for index + 1 < text.len() + 1 {
            if index + 2 > text.len() { break }
            out.push(hex_byte(text.slice(index, index + 2)))
            index = index + 2
        }
        return move out
    }
    var index: int = 0
    for index < text.len() {
        if (text.byte_at(index) as int) == 92 && index + 1 < text.len() {
            let next: int = text.byte_at(index + 1) as int
            if next == 92 {
                out.push(92)
                index = index + 2
                continue
            }
            if index + 3 < text.len() {
                // \nnn, three octal digits.
                let octal: string = text.slice(index + 1, index + 4)
                out.push(octal_byte(octal))
                index = index + 4
                continue
            }
        }
        out.push(text.byte_at(index) as int)
        index = index + 1
    }
    return move out
}

fn hex_byte(pair: string) -> int {
    return hex_digit(pair.byte_at(0) as int) * 16 + hex_digit(pair.byte_at(1) as int)
}

fn hex_digit(byte: int) -> int {
    if byte >= 48 && byte <= 57 { return byte - 48 }
    if byte >= 97 && byte <= 102 { return byte - 87 }
    if byte >= 65 && byte <= 70 { return byte - 55 }
    return 0
}

fn octal_byte(triple: string) -> int {
    var value: int = 0
    for index: int in 0..triple.len() {
        value = value * 8 + ((triple.byte_at(index) as int) - 48)
    }
    return value % 256
}

/// `{1,2,NULL}` and `{"a,b","c"}`. One dimension; a nested array decodes to
/// its text, because a `Value` array has no depth and guessing one would be
/// worse than saying so.
pub fn decode_array(element: int, text: string) -> List<dbcore.Value> {
    var out: List<dbcore.Value> = []
    if text.len() < 2 { return move out }
    let body: string = text.slice(1, text.len() - 1)
    if body == "" { return move out }
    var current: string = ""
    var quoted: bool = false
    var escaped: bool = false
    var had_quotes: bool = false
    var depth: int = 0
    for index: int in 0..body.len() {
        let piece: string = body.slice(index, index + 1)
        let byte: int = body.byte_at(index) as int
        if escaped { current = "{current}{piece}"; escaped = false; continue }
        if quoted {
            if byte == 92 { escaped = true; continue }
            if byte == 34 { quoted = false; continue }
            current = "{current}{piece}"
            continue
        }
        if byte == 34 { quoted = true; had_quotes = true; continue }
        if byte == 123 { depth = depth + 1 }
        if byte == 125 { depth = depth - 1 }
        if byte == 44 && depth == 0 {
            out.push(array_cell(element, current, had_quotes))
            current = ""
            had_quotes = false
            continue
        }
        current = "{current}{piece}"
    }
    out.push(array_cell(element, current, had_quotes))
    return move out
}

// An unquoted NULL is the null element; a quoted "NULL" is the four letters.
fn array_cell(element: int, text: string, quoted: bool) -> dbcore.Value {
    if !quoted && text == "NULL" { return dbcore.Value.null() }
    return decode_text(element, text)
}
