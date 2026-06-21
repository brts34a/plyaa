# iOS Geliştirme Kuralları

- Bir kod değiştirirken, güncellerken her şeyi eksiksiz iOS'un kaynakları ve desteği ne istiyorsa ona uygun şekilde uygulayacaksın.
- Arayüze sahte/boş bir kutu ekleyip geçiştirmek kesinlikle YASAKTIR. Tüm özellikler eksiksiz çalışmalıdır.
- "Exit code 65" veya derleme hatalarını önlemek için, her kod güncellemesinde kodun doğru kullanıldığından (örn. iOS'a ait `.leading`, geçerli metot isimleri) mutlaka emin olacaksın.
- Her güncellemede uygulamanın optimizasyonuna (CPU, GPU ve pil kullanımı) çok dikkat edeceksin. Gereksiz veya sık çalışan döngüleri, timer'ları, view render'larını ve @Published tetiklemelerini engelleyeceksin. SwiftUI'da sadece değişen değerlerde state güncelleyecek, ısınmaya veya şarj tüketimine neden olabilecek gereksiz yeniden çizimleri (re-render) kesinlikle önleyeceksin.
