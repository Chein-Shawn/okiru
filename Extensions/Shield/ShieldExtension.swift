import ManagedSettings
import ManagedSettingsUI
import UIKit

final class ShieldExtension: ShieldConfigurationDataSource {
    private var configuration: ShieldConfiguration {
        ShieldConfiguration(backgroundBlurStyle: .systemMaterialDark, backgroundColor: .systemBackground,
                            icon: UIImage(systemName:"sunrise.fill"), title:.init(text:"Okiru",color:.label),
                            subtitle:.init(text:tr("shield.message.dynamic"),color:.secondaryLabel),
                            primaryButtonLabel:.init(text:tr("close"),color:.white), primaryButtonBackgroundColor:.systemOrange)
    }
    override func configuration(shielding application: Application) -> ShieldConfiguration { configuration }
    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration { configuration }
    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration { configuration }
    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration { configuration }
}
