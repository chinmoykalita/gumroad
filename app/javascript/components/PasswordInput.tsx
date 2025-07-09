import * as React from "react";

import { Icon } from "$app/components/Icons";

type PasswordInputProps = Omit<React.ComponentPropsWithoutRef<"input">, "type"> & {
  value: string;
  onChange: (e: React.ChangeEvent<HTMLInputElement>) => void;
};

export const PasswordInput = React.forwardRef<HTMLInputElement, PasswordInputProps>(({ className, ...props }, ref) => {
  const [showPassword, setShowPassword] = React.useState(false);

  const togglePasswordVisibility = () => {
    setShowPassword(!showPassword);
  };

  return (
    <div className="input">
      <input ref={ref} type={showPassword ? "text" : "password"} className={className} {...props} />
      <Icon
        name={showPassword ? "eye-slash" : "eye"}
        onClick={togglePasswordVisibility}
        role="button"
        tabIndex={0}
        style={{ cursor: "pointer" }}
        aria-label={showPassword ? "Hide password" : "Show password"}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            togglePasswordVisibility();
          }
        }}
      />
    </div>
  );
});

PasswordInput.displayName = "PasswordInput";
