pub const block = struct {
    pub const tokens = 1 << 14;
};

pub const match = struct {
    pub const base_length = 3; // smallest match length per the RFC section 3.2.5
    pub const min_length = 4; // min length used in this algorithm
    pub const max_length = 258;

    pub const min_distance = 1;
    pub const max_distance = 32768;
};

pub const window = struct { // TODO: consider renaming this into history
    pub const bits = 15;
    pub const size = 1 << bits;
    pub const mask = size - 1;
};

pub const hash = struct {
    pub const bits = 17;
    pub const size = 1 << bits;
    pub const mask = size - 1;
    pub const shift = 32 - bits;
};
