import ReactOnRails from "react-on-rails";

import BasePage from "$app/utils/base_page";

import ChurnPage from "$app/components/server-components/ChurnPage";

BasePage.initialize();

ReactOnRails.default.register({ ChurnPage });
