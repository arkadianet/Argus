//! The loan assets SigmaFi's interface offers.

use serde::Serialize;

#[derive(Debug, Clone, Copy, Serialize)]
pub struct LoanToken {
    /// `"ERG"` or a token id.
    pub id: &'static str,
    pub name: &'static str,
    pub decimals: u8,
}

pub const LOAN_TOKENS: &[LoanToken] = &[
    LoanToken { id: "ERG", name: "ERG", decimals: 9 },
    LoanToken {
        id: "03faf2cb329f2e90d6d23b58d91bbb6c046aa143261cc21f52fbe2824bfcbf04",
        name: "SigUSD",
        decimals: 2,
    },
    LoanToken {
        id: "003bd19d0187117f130b62e1bcab0939929ff5c7709f843c5c4dd158949285d0",
        name: "SigRSV",
        decimals: 0,
    },
    LoanToken {
        id: "7a51950e5f548549ec1aa63ffdc38279505b11e7e803d01bcf8347e0123c88b0",
        name: "rsBTC",
        decimals: 8,
    },
    LoanToken {
        id: "e023c5f382b6e96fbd878f6811aac73345489032157ad5affb84aefd4956c297",
        name: "rsADA",
        decimals: 6,
    },
    LoanToken {
        id: "8b08cdd5449a9592a9e79711d7d79249d7a03c535d17efaee83e216e80a44c4b",
        name: "RSN",
        decimals: 3,
    },
    LoanToken {
        id: "9a06d9e545a41fd51eeffc5e20d818073bf820c635e2a9d922269913e0de369d",
        name: "SPF",
        decimals: 6,
    },
];

pub fn loan_token(id: &str) -> Option<&'static LoanToken> {
    LOAN_TOKENS.iter().find(|t| t.id.eq_ignore_ascii_case(id))
}
