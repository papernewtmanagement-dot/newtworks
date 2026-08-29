import React from "react";
export const useTabParam = (n, d) => { const [v, s] = React.useState(d); return [v, s, () => "#"]; };
export const TabLink = ({ children }) => React.createElement("a", { href: "#" }, children);
