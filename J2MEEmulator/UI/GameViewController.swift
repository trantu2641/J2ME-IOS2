
@objc private func handleKeyboardWillChangeFrame(
    _ notification: Notification
) {

    guard let userInfo = notification.userInfo,
          let screenFrame = userInfo[
            UIResponder.keyboardFrameEndUserInfoKey
          ] as? CGRect else {
        return
    }

    let keyboardFrame = view.convert(
        screenFrame,
        from: nil
    )

    let intersection = view.bounds.intersection(keyboardFrame)

    let systemKeyboardVisible =
        !intersection.isNull &&
        intersection.width >= view.bounds.width * 0.5 &&
        intersection.height > 80

    let duration = userInfo[
        UIResponder.keyboardAnimationDurationUserInfoKey
    ] as? Double ?? 0.25

    let curve = userInfo[
        UIResponder.keyboardAnimationCurveUserInfoKey
    ] as? UInt ?? 7

    let animationOptions =
        UIView.AnimationOptions(rawValue: curve << 16)
            .union(.beginFromCurrentState)

    // Tính khoảng cách từ cạnh dưới vùng an toàn
    // đến cạnh trên bàn phím iPhone.
    let keyboardInset: CGFloat

    if systemKeyboardVisible {
        keyboardInset = max(
            0,
            view.safeAreaLayoutGuide.layoutFrame.maxY
                - keyboardFrame.minY
        )
    } else {
        keyboardInset = 0
    }

    // Đẩy vùng hiển thị JAR lên đúng theo chiều cao bàn phím.
    keypadBottomConstraint.constant = -(keyboardInset + 7)

    if systemKeyboardVisible {

        keyboardIsVisible = true

        // Thu gọn bàn phím J2ME.
        // Màn hình JAR sẽ nằm phía trên bàn phím iPhone.
        setKeypadVisible(
            false,
            duration: duration,
            animationOptions: animationOptions
        )

    } else {

        keyboardIsVisible = false

        // Đóng bàn phím iPhone thì khôi phục bàn phím J2ME.
        if isCanvasScreenVisible && !userRequestedExit {

            setKeypadVisible(
                true,
                duration: duration,
                animationOptions: animationOptions
            )

        } else {

            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: animationOptions,
                animations: {
                    self.view.layoutIfNeeded()
                }
            )
        }
    }
}
