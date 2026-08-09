import UIKit

private final class ClipButton: UIButton {
    var clipText = ""
}

class CaptureKeyboardViewController: UIInputViewController {

    private var stackView: UIStackView!
    private var scrollView: UIScrollView!
    private var clipsStackView: UIStackView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        loadClipboardClips()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadClipboardClips()
    }

    private func setupUI() {
        view.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1.0) // #18181B

        stackView = UIStackView()
        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.distribution = .fill
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stackView)

        let headerLabel = UILabel()
        headerLabel.text = "✨ AUGUSTYNIAK CAPTURE"
        headerLabel.textColor = UIColor(red: 0.89, green: 0.89, blue: 0.91, alpha: 1.0)
        headerLabel.font = UIFont.systemFont(ofSize: 13, weight: .bold)

        scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = false

        clipsStackView = UIStackView()
        clipsStackView.axis = .horizontal
        clipsStackView.spacing = 8
        clipsStackView.alignment = .center
        clipsStackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(clipsStackView)

        stackView.addArrangedSubview(headerLabel)
        stackView.addArrangedSubview(scrollView)

        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stackView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stackView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            scrollView.heightAnchor.constraint(equalToConstant: 44),
            clipsStackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            clipsStackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            clipsStackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            clipsStackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            clipsStackView.heightAnchor.constraint(equalTo: scrollView.heightAnchor)
        ])
    }

    private func loadClipboardClips() {
        clipsStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        var clips: [String] = []

        let sharedContainer = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.ai.augustyniak.capture"
        )
        let fileURL = sharedContainer?
            .appendingPathComponent("AugustyniakCapture", isDirectory: true)
            .appendingPathComponent("clipboard_history.json")

        if let url = fileURL, let data = try? Data(contentsOf: url),
           let jsonArray = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [[String: Any]] {
            for item in jsonArray {
                if let text = item["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    clips.append(text)
                }
            }
        }

        if clips.isEmpty {
            let emptyLabel = UILabel()
            emptyLabel.text = "No copied items in the clipboard"
            emptyLabel.textColor = UIColor(red: 0.44, green: 0.44, blue: 0.48, alpha: 1.0)
            emptyLabel.font = UIFont.systemFont(ofSize: 12)
            clipsStackView.addArrangedSubview(emptyLabel)
            return
        }

        for clipText in clips {
            let button = ClipButton(type: .system)
            button.clipText = clipText
            let preview = clipText.count > 30 ? String(clipText.prefix(30)) + "..." : clipText
            button.setTitle(preview, for: .normal)
            button.setTitleColor(.white, for: .normal)
            button.backgroundColor = UIColor(red: 0.15, green: 0.15, blue: 0.16, alpha: 1.0)
            button.titleLabel?.font = UIFont.systemFont(ofSize: 12)
            button.contentEdgeInsets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
            button.layer.cornerRadius = 8

            button.addTarget(self, action: #selector(insertClip(_:)), for: .touchUpInside)

            clipsStackView.addArrangedSubview(button)
        }
    }

    @objc private func insertClip(_ sender: ClipButton) {
        textDocumentProxy.insertText(sender.clipText)
    }
}
