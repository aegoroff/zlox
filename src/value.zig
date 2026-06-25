pub const LoxValue = union(enum) {
    Number: f64,
    Bool: bool,
};